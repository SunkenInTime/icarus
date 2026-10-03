use std::{
    collections::BTreeMap,
    convert::Infallible,
    time::Duration,
};

use convex_sync_types::{
    backoff::Backoff,
    UdfPath,
};
use tokio::sync::{
    broadcast,
    mpsc,
    oneshot,
};
use tokio_stream::wrappers::BroadcastStream;

use crate::{
    base_client::{
        AuthTokenFetcher,
        BaseConvexClient,
        SubscriberId,
    },
    client::{
        QueryResults,
        QuerySubscription,
    },
    sync::{
        ProtocolResponse,
        ReconnectProtocolReason,
        ReconnectRequest,
        SyncProtocol,
    },
    value::Value,
    FunctionResult,
};

const INITIAL_BACKOFF: Duration = Duration::from_millis(100);
const MAX_BACKOFF: Duration = Duration::from_secs(15);
const AUTH_RETRY_DELAY: Duration = Duration::from_millis(250);

fn is_auth_rejection(reason: &str) -> bool {
    reason.starts_with("AuthError:")
}

#[derive(Default)]
struct AuthRecovery {
    active: bool,
    fresh_token_in_flight: bool,
}

pub enum ClientRequest {
    Mutation(
        MutationRequest,
        oneshot::Sender<oneshot::Receiver<FunctionResult>>,
    ),
    Action(
        ActionRequest,
        oneshot::Sender<oneshot::Receiver<FunctionResult>>,
    ),
    Subscribe(
        SubscribeRequest,
        oneshot::Sender<QuerySubscription>,
        mpsc::UnboundedSender<ClientRequest>,
    ),
    Unsubscribe(UnsubscribeRequest),
    Authenticate(Option<AuthTokenFetcher>),
    Reconnect(String),
}

pub struct MutationRequest {
    pub udf_path: UdfPath,
    pub args: BTreeMap<String, Value>,
}

pub struct ActionRequest {
    pub udf_path: UdfPath,
    pub args: BTreeMap<String, Value>,
}

pub struct SubscribeRequest {
    pub udf_path: UdfPath,
    pub args: BTreeMap<String, Value>,
}

#[derive(Debug)]
pub struct UnsubscribeRequest {
    pub subscriber_id: SubscriberId,
}

pub async fn worker<T: SyncProtocol>(
    mut protocol_response_receiver: mpsc::Receiver<ProtocolResponse>,
    mut client_request_receiver: mpsc::UnboundedReceiver<ClientRequest>,
    mut watch_sender: broadcast::Sender<QueryResults>,
    mut base_client: BaseConvexClient,
    mut protocol_manager: T,
) -> Infallible {
    let mut backoff = Backoff::new(INITIAL_BACKOFF, MAX_BACKOFF);
    let mut auth_recovery = AuthRecovery::default();
    loop {
        let e = loop {
            match _worker_once(
                &mut protocol_response_receiver,
                &mut client_request_receiver,
                &mut watch_sender,
                &mut base_client,
                &mut protocol_manager,
                &mut auth_recovery,
            )
            .await
            {
                Ok(()) => backoff.reset(),
                Err(e) => break e,
            }
        };

        if is_auth_rejection(&e) {
            auth_recovery.active = true;
            auth_recovery.fresh_token_in_flight = false;
        }

        // A server auth rejection and the protocol errors cascading from that
        // rejected socket are not network outages. The reconnect below
        // invokes the stored token callback with `force_refresh=true`, so retry
        // it at a small fixed cadence while the auth provider obtains a fresh
        // token. Applying the generic exponential network backoff here can
        // otherwise delay a ready token for up to MAX_BACKOFF.
        let delay = if auth_recovery.active {
            backoff.reset();
            AUTH_RETRY_DELAY
        } else {
            backoff.fail(&mut rand::rng())
        };
        tracing::error!(
            "Convex Client Worker failed: {e:?}. Backing off for {delay:?} and retrying."
        );
        tokio::time::sleep(delay).await;

        // Everything currently buffered came from the connection we are about
        // to replace. In particular, an auth error can be followed by the old
        // socket closing and queuing ProtocolFailure while this worker is in
        // its retry delay. Replaying that stale failure after the new socket is
        // up starts a second, unrelated backoff and can leave fresh auth behind
        // it. Query and mutation state is rebuilt below, so discard the old
        // connection's buffered responses before requesting the replacement.
        while protocol_response_receiver.try_recv().is_ok() {}

        // Tell the sync protocol to reconnect followed by an immediate resend of
        // ongoing queries/mutations. It's important these happen together to
        // ensure mutation ordering. If an auth token fetcher is stored,
        // resend_ongoing_queries_mutations will refresh the token first.
        protocol_manager
            .reconnect(ReconnectRequest {
                reason: e,
                max_observed_timestamp: base_client.max_observed_timestamp(),
                auth_retry: auth_recovery.active,
            })
            .await;
        let auth_token_changed = base_client.resend_ongoing_queries_mutations().await;
        if auth_recovery.active && auth_token_changed {
            auth_recovery.fresh_token_in_flight = true;
        }
        // We'll flush messages from base_client inside the next call to
        // `_worker_once`.
    }
}

#[cfg(test)]
mod tests {
    use super::is_auth_rejection;

    #[test]
    fn only_server_auth_errors_use_the_auth_retry_path() {
        assert!(is_auth_rejection(
            "AuthError: token expired for identity version 1"
        ));
        assert!(!is_auth_rejection("ProtocolFailure"));
        assert!(!is_auth_rejection("convex_flutter:manual"));
    }
}

async fn _worker_once<T: SyncProtocol>(
    protocol_response_receiver: &mut mpsc::Receiver<ProtocolResponse>,
    client_request_receiver: &mut mpsc::UnboundedReceiver<ClientRequest>,
    watch_sender: &mut broadcast::Sender<QueryResults>,
    base_client: &mut BaseConvexClient,
    protocol_manager: &mut T,
    auth_recovery: &mut AuthRecovery,
) -> Result<(), ReconnectProtocolReason> {
    // If there are any outgoing messages to flush (e.g. from an outer reconnect),
    // do so first.
    communicate(
        base_client,
        protocol_response_receiver,
        watch_sender,
        protocol_manager,
        auth_recovery,
    )
    .await?;

    tokio::select! {
        Some(protocol_response) = protocol_response_receiver.recv() => {
            handle_protocol_response(
                base_client,
                watch_sender,
                protocol_response,
                auth_recovery,
            )?;
        }
        Some(client_request) = client_request_receiver.recv() => {
            match client_request {
                ClientRequest::Subscribe(query, tx, request_sender) => {
                    let watch = watch_sender.subscribe();
                    let SubscribeRequest {
                        udf_path,
                        args,
                    } =  query;
                    let subscriber_id = base_client.subscribe(udf_path, args);
                    communicate(
                        base_client,
                        protocol_response_receiver,
                        watch_sender,
                        protocol_manager,
                        auth_recovery,
                    )
                    .await?;

                    let watch = BroadcastStream::new(watch);
                    let subscription = QuerySubscription {
                        subscriber_id,
                        request_sender,
                        watch,
                        initial: base_client.latest_results().get(&subscriber_id).cloned(),
                    };
                    let _ = tx.send(subscription);
                },
                ClientRequest::Mutation(mutation, tx) => {
                    let MutationRequest {
                        udf_path,
                        args,
                    } = mutation;
                    let result_receiver = base_client
                        .mutation(udf_path, args);
                        communicate(
                            base_client,
                            protocol_response_receiver,
                            watch_sender,
                            protocol_manager,
                            auth_recovery,
                        )
                        .await?;
                    let _ = tx.send(result_receiver);
                },
                ClientRequest::Action(action, tx) => {
                    let ActionRequest {
                        udf_path,
                        args,
                    } = action;
                    let result_receiver = base_client
                        .action(udf_path, args);
                        communicate(
                            base_client,
                            protocol_response_receiver,
                            watch_sender,
                            protocol_manager,
                            auth_recovery,
                        )
                        .await?;
                    let _ = tx.send(result_receiver);
                },
                ClientRequest::Unsubscribe(unsubscribe) => {
                    let UnsubscribeRequest {subscriber_id} = unsubscribe;
                    base_client.unsubscribe(subscriber_id);
                    communicate(
                        base_client,
                        protocol_response_receiver,
                        watch_sender,
                        protocol_manager,
                        auth_recovery,
                    )
                    .await?;
                },
                ClientRequest::Authenticate(fetcher) => {
                    let token_changed = base_client.set_auth_fetcher(fetcher).await;
                    if auth_recovery.active && token_changed {
                        auth_recovery.fresh_token_in_flight = true;
                    }
                    communicate(
                        base_client,
                        protocol_response_receiver,
                        watch_sender,
                        protocol_manager,
                        auth_recovery,
                    )
                    .await?;
                },
                ClientRequest::Reconnect(reason) => return Err(reason),
            }
        },
        // TODO: this else branch will lead to an infinite loop if both channels
        // are closed
        else => (),
    }
    Ok(())
}

/// Flush all messages to the protocol while processing server mesages.
async fn communicate<P: SyncProtocol>(
    base_client: &mut BaseConvexClient,
    protocol_response_receiver: &mut mpsc::Receiver<ProtocolResponse>,
    watch_sender: &mut broadcast::Sender<QueryResults>,
    protocol: &mut P,
    auth_recovery: &mut AuthRecovery,
) -> Result<(), ReconnectProtocolReason> {
    while let Some(modification) = base_client.pop_next_message() {
        let mut send_future = protocol.send(modification);
        loop {
            tokio::select! {
               _ = &mut send_future => break,
               // Keep processing protocol responses while waiting so that we
               // don't deadlock with the websocket worker.
               Some(protocol_response) = protocol_response_receiver.recv() => {
                   handle_protocol_response(
                       base_client,
                       watch_sender,
                       protocol_response,
                       auth_recovery,
                   )?;
               }
            }
        }
    }
    Ok(())
}

fn handle_protocol_response(
    base_client: &mut BaseConvexClient,
    watch_sender: &mut broadcast::Sender<QueryResults>,
    protocol_response: ProtocolResponse,
    auth_recovery: &mut AuthRecovery,
) -> Result<(), ReconnectProtocolReason> {
    match protocol_response {
        ProtocolResponse::ServerMessage(msg) => {
            let proves_protocol_auth = matches!(
                &msg,
                crate::sync::ServerMessage::Transition { .. }
                    | crate::sync::ServerMessage::MutationResponse { .. }
                    | crate::sync::ServerMessage::ActionResponse { .. }
            );
            if let Some(subscriber_id_to_latest_value) = base_client.receive_message(msg)? {
                // Notify watchers of the new consistent query results at new timestamp
                let _ = watch_sender.send(subscriber_id_to_latest_value);
            }
            if proves_protocol_auth && auth_recovery.fresh_token_in_flight {
                // Only a response after the refresh callback produced a
                // different token proves recovery. Transitions buffered while
                // the rejected token was still current cannot clear this state.
                auth_recovery.active = false;
                auth_recovery.fresh_token_in_flight = false;
            }
        },
        ProtocolResponse::Failure => {
            return Err("ProtocolFailure".into());
        },
    }
    Ok(())
}
