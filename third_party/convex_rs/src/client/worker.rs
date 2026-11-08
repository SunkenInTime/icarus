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
        subscription::{
            QuerySetSubscription,
            SubscribedSet,
        },
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
    SubscribeSet(
        Vec<SubscribeRequest>,
        oneshot::Sender<SubscribedSet>,
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
        // Until the protocol acknowledges the reconnect, responses still come
        // from the connection being replaced. Handle them against the state
        // they belong to, before it's resent below, so an action or mutation
        // that connection already answered completes instead of being sent
        // again. Ignore their errors: that connection is already being
        // replaced. Otherwise its failure (the server closes the socket right
        // after an AuthError, say) would reconnect a second time, and its
        // transitions would hit the new state.
        while let Some(protocol_response) = protocol_response_receiver.recv().await {
            if let ProtocolResponse::ReconnectAcknowledged = protocol_response {
                break;
            }
            let _ = handle_protocol_response(
                &mut base_client,
                &mut watch_sender,
                protocol_response,
                &mut auth_recovery,
            );
        }
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
    use std::{
        collections::BTreeMap,
        str::FromStr,
        sync::Arc,
        time::Duration,
    };

    use async_trait::async_trait;
    use convex_sync_types::{
        ClientMessage,
        LogLinesMessage,
        UdfPath,
    };
    use parking_lot::Mutex;
    use tokio::sync::{
        broadcast,
        mpsc,
        oneshot,
    };
    use url::Url;

    use super::{
        is_auth_rejection,
        worker,
        ActionRequest,
        ClientRequest,
    };
    use crate::{
        base_client::BaseConvexClient,
        sync::{
            ProtocolResponse,
            ReconnectRequest,
            ServerMessage,
            SyncProtocol,
            WebSocketState,
        },
        value::Value,
        FunctionResult,
    };

    #[test]
    fn only_server_auth_errors_use_the_auth_retry_path() {
        assert!(is_auth_rejection(
            "AuthError: token expired for identity version 1"
        ));
        assert!(!is_auth_rejection("ProtocolFailure"));
        assert!(!is_auth_rejection("convex_flutter:manual"));
    }

    /// Records what the worker sends and the reconnects it asks for. Like the
    /// WebSocket worker, it delivers responses still read from the old
    /// connection after a reconnect is requested, then acknowledges it.
    #[derive(Clone)]
    struct FakeProtocol {
        response_sender: mpsc::Sender<ProtocolResponse>,
        late_responses: Arc<Mutex<Vec<ProtocolResponse>>>,
        sent: Arc<Mutex<Vec<ClientMessage>>>,
        reconnects: Arc<Mutex<Vec<String>>>,
    }

    impl FakeProtocol {
        fn new(response_sender: mpsc::Sender<ProtocolResponse>) -> Self {
            Self {
                response_sender,
                late_responses: Arc::default(),
                sent: Arc::default(),
                reconnects: Arc::default(),
            }
        }

        async fn wait_for_sent(&self, n: usize) -> anyhow::Result<()> {
            tokio::time::timeout(Duration::from_secs(2), async {
                while self.sent.lock().len() < n {
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
            })
            .await?;
            Ok(())
        }

        fn sent_actions(&self) -> usize {
            self.sent
                .lock()
                .iter()
                .filter(|message| matches!(message, ClientMessage::Action { .. }))
                .count()
        }
    }

    #[async_trait]
    impl SyncProtocol for FakeProtocol {
        async fn open(
            _ws_url: Url,
            _on_response: mpsc::Sender<ProtocolResponse>,
            _on_state_change: Option<mpsc::Sender<WebSocketState>>,
            _client_id: &str,
        ) -> anyhow::Result<Self> {
            unimplemented!()
        }

        async fn send(&mut self, message: ClientMessage) -> anyhow::Result<()> {
            self.sent.lock().push(message);
            Ok(())
        }

        async fn reconnect(&mut self, request: ReconnectRequest) {
            self.reconnects.lock().push(request.reason);
            let late_responses = std::mem::take(&mut *self.late_responses.lock());
            let response_sender = self.response_sender.clone();
            tokio::spawn(async move {
                for response in late_responses {
                    let _ = response_sender.send(response).await;
                }
                let _ = response_sender
                    .send(ProtocolResponse::ReconnectAcknowledged)
                    .await;
            });
        }
    }

    fn start_worker(
        protocol: &FakeProtocol,
        response_receiver: mpsc::Receiver<ProtocolResponse>,
    ) -> (
        mpsc::UnboundedSender<ClientRequest>,
        tokio::task::JoinHandle<std::convert::Infallible>,
    ) {
        let (request_sender, request_receiver) = mpsc::unbounded_channel();
        let (watch_sender, _watch_receiver) = broadcast::channel(1);
        let handle = tokio::spawn(worker(
            response_receiver,
            request_receiver,
            watch_sender,
            BaseConvexClient::new(),
            protocol.clone(),
        ));
        (request_sender, handle)
    }

    #[tokio::test]
    async fn test_old_socket_failure_after_auth_error_reconnects_once() -> anyhow::Result<()> {
        let (response_sender, response_receiver) = mpsc::channel(1);
        let protocol = FakeProtocol::new(response_sender.clone());
        // The server closes the socket right after rejecting the token, and
        // the WebSocket worker reports that after the reconnect is requested.
        protocol
            .late_responses
            .lock()
            .push(ProtocolResponse::Failure);
        let (_request_sender, worker) = start_worker(&protocol, response_receiver);

        response_sender
            .send(ProtocolResponse::ServerMessage(ServerMessage::AuthError {
                error_message: "Token expired".into(),
                base_version: None,
                auth_update_attempted: Some(false),
            }))
            .await?;

        // Wait for the state to be resent on the new connection, then for
        // longer than the auth retry delay before a second reconnect.
        protocol.wait_for_sent(1).await?;
        tokio::time::sleep(Duration::from_secs(1)).await;
        worker.abort();
        let reconnects = protocol.reconnects.lock();
        assert_eq!(reconnects.len(), 1, "reconnected for {reconnects:?}");
        Ok(())
    }

    #[tokio::test]
    async fn test_action_answered_by_the_old_socket_is_not_sent_again() -> anyhow::Result<()> {
        let (response_sender, response_receiver) = mpsc::channel(1);
        let protocol = FakeProtocol::new(response_sender.clone());
        let (request_sender, worker) = start_worker(&protocol, response_receiver);

        let (tx, rx) = oneshot::channel();
        request_sender.send(ClientRequest::Action(
            ActionRequest {
                udf_path: UdfPath::from_str("images:generateUploadUrl")?,
                args: BTreeMap::new(),
            },
            tx,
        ))?;
        let result = rx.await?;
        protocol.wait_for_sent(1).await?;
        assert_eq!(protocol.sent_actions(), 1);

        // The app asks for a reconnect while the action runs, and the old
        // socket still delivers its result before it closes.
        protocol
            .late_responses
            .lock()
            .push(ProtocolResponse::ServerMessage(
                ServerMessage::ActionResponse {
                    request_id: 0,
                    result: FunctionResult::Value(Value::from("upload url")).into(),
                    log_lines: LogLinesMessage(vec![]),
                },
            ));
        request_sender.send(ClientRequest::Reconnect("convex_flutter:manual".into()))?;

        let result = tokio::time::timeout(Duration::from_secs(2), result).await??;
        assert_eq!(result, FunctionResult::Value(Value::from("upload url")));
        // Give the resend time to happen, then check it left the action out.
        tokio::time::sleep(Duration::from_millis(500)).await;
        worker.abort();
        assert_eq!(protocol.reconnects.lock().len(), 1);
        assert_eq!(
            protocol.sent_actions(),
            1,
            "the finished action was sent again: {:?}",
            protocol.sent.lock()
        );
        Ok(())
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
                ClientRequest::SubscribeSet(queries, tx, request_sender) => {
                    // The tokens exist before anything that can fail, so a
                    // failure drops them and unsubscribes every query.
                    let subscriptions: Vec<QuerySubscription> = queries
                        .into_iter()
                        .map(|SubscribeRequest { udf_path, args }| QuerySubscription {
                            subscriber_id: base_client.subscribe(udf_path, args),
                            request_sender: request_sender.clone(),
                            watch: BroadcastStream::new(watch_sender.subscribe()),
                            initial: None,
                        })
                        .collect();
                    communicate(
                        base_client,
                        protocol_response_receiver,
                        watch_sender,
                        protocol_manager,
                        auth_recovery,
                    )
                    .await?;

                    // Taken with nothing awaited in between: every update
                    // the watch yields is newer than these results.
                    let results = base_client.latest_results().clone();
                    let updates =
                        QuerySetSubscription::new(BroadcastStream::new(watch_sender.subscribe()));
                    let _ = tx.send(SubscribedSet {
                        subscriptions,
                        results,
                        updates,
                    });
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
        // Only expected after a reconnect request, where `worker` waits for it.
        ProtocolResponse::ReconnectAcknowledged => {},
    }
    Ok(())
}
