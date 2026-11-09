use std::{
    collections::BTreeMap,
    convert::Infallible,
    sync::Arc,
    time::Duration,
};

use convex_sync_types::{
    backoff::Backoff,
    UdfPath,
};
use rand::Rng;
use tokio::sync::{
    broadcast,
    mpsc,
    oneshot,
    watch,
    Notify,
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
/// The longest wait before the first retry after the server refuses auth.
/// The retry asks the token callback for a fresh token, and an expired token
/// usually gets one right away, so this stays short.
const AUTH_RETRY_DELAY: Duration = Duration::from_millis(250);
/// After this many refusals in a row, [`AuthRecovery::refused`] reports the
/// session as refused. With the waits doubling from AUTH_RETRY_DELAY, the
/// retries have spent a couple of seconds by then, far longer than a token
/// refresh takes.
pub const AUTH_REFUSALS_TO_REPORT: u32 = 5;

fn is_auth_rejection(reason: &str) -> bool {
    reason.starts_with("AuthError:")
}

/// How long to wait before retrying after the server refused auth
/// `refusals` times in a row: AUTH_RETRY_DELAY, doubling with each refusal
/// up to MAX_BACKOFF, less up to half at random so clients refused together
/// don't retry together.
fn auth_retry_delay(refusals: u32) -> Duration {
    let doublings = refusals.saturating_sub(1).min(16);
    let full = AUTH_RETRY_DELAY
        .saturating_mul(1 << doublings)
        .min(MAX_BACKOFF);
    full.mul_f64(rand::rng().random_range(0.5..=1.0))
}

struct AuthRecovery {
    active: bool,
    /// Auth went to the server again since its last refusal, on a new
    /// connection or as a different token. The server's next answer proves
    /// it accepted that auth.
    auth_resent: bool,
    /// Refusals since the server last accepted a token.
    refusals: u32,
    /// True once the server has refused AUTH_REFUSALS_TO_REPORT times in a
    /// row, until it accepts a token again.
    refused: watch::Sender<bool>,
}

impl AuthRecovery {
    fn new(refused: watch::Sender<bool>) -> Self {
        Self {
            active: false,
            auth_resent: false,
            refusals: 0,
            refused,
        }
    }
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
    reconnect_requested: Arc<Notify>,
    auth_refused: watch::Sender<bool>,
) -> Infallible {
    let mut backoff = Backoff::new(INITIAL_BACKOFF, MAX_BACKOFF);
    let mut auth_recovery = AuthRecovery::new(auth_refused);
    loop {
        let e = loop {
            match _worker_once(
                &mut protocol_response_receiver,
                &mut client_request_receiver,
                &mut watch_sender,
                &mut base_client,
                &mut protocol_manager,
                &mut auth_recovery,
                &reconnect_requested,
            )
            .await
            {
                Ok(()) => backoff.reset(),
                Err(e) => break e,
            }
        };

        // A server auth rejection is not a network outage. The reconnect
        // below invokes the stored token callback with `force_refresh=true`,
        // so the first retry comes quickly, in case the callback has a fresh
        // token. Each refusal after that doubles the wait: a token the server
        // keeps refusing (a removed account, a misconfigured issuer, a clock
        // that's off) must not reconnect several times a second forever.
        let auth_refused = is_auth_rejection(&e);
        let delay = if auth_refused {
            auth_recovery.active = true;
            auth_recovery.auth_resent = false;
            auth_recovery.refusals += 1;
            if auth_recovery.refusals == AUTH_REFUSALS_TO_REPORT {
                auth_recovery.refused.send_replace(true);
            }
            backoff.reset();
            auth_retry_delay(auth_recovery.refusals)
        } else {
            backoff.fail(&mut rand::rng())
        };
        tracing::error!(
            "Convex Client Worker failed: {e:?}. Backing off for {delay:?} and retrying."
        );
        if auth_refused {
            // The app asks for a reconnect when it has new auth for the
            // client, such as a token its provider just refreshed, or when
            // the user retries. Don't keep that waiting behind the backoff,
            // even if it asked just before this wait began: `reconnect_now`
            // leaves a permit for that.
            let reconnect_requested = reconnect_requested.notified();
            tokio::select! {
                _ = tokio::time::sleep(delay) => {},
                _ = reconnect_requested => {},
            }
        } else {
            tokio::time::sleep(delay).await;
        }

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
        let sends_auth = base_client.resend_ongoing_queries_mutations().await;
        // Everything the old connection sent was handled above, so from here
        // on answers come from the new connection, and the server only
        // answers there after accepting the auth this resend sends first.
        // That's true of the same token too: the server may accept a token it
        // refused before (its auth config was fixed, say). A resend without
        // auth proves nothing: the server answers anonymous clients too, and
        // auth an earlier connection sent is gone with it.
        if auth_recovery.active {
            auth_recovery.auth_resent = sends_auth;
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
        AuthenticationToken,
        ClientMessage,
        LogLinesMessage,
        QuerySetModification,
        StateVersion,
        UdfPath,
    };
    use parking_lot::Mutex;
    use tokio::sync::{
        broadcast,
        mpsc,
        oneshot,
        watch,
        Notify,
    };
    use url::Url;

    use super::{
        is_auth_rejection,
        worker,
        ActionRequest,
        ClientRequest,
        MutationRequest,
        SubscribeRequest,
        AUTH_REFUSALS_TO_REPORT,
    };
    use crate::{
        base_client::{
            AuthTokenFetcher,
            BaseConvexClient,
        },
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
        /// What the server does on each new connection.
        server: Arc<Mutex<Server>>,
        /// How long a mutation or action takes to finish sending once it's
        /// on the socket, as a slow one would.
        request_send_time: Arc<Mutex<Duration>>,
        /// The same for a change to the query set.
        query_set_send_time: Arc<Mutex<Duration>>,
    }

    #[derive(Clone, Copy)]
    enum Server {
        Quiet,
        /// Refuses the client's auth, as it does a token it can't accept.
        RefuseAuth,
        /// Accepts the client's auth and answers with a transition.
        AcceptAuth,
    }

    impl FakeProtocol {
        fn new(response_sender: mpsc::Sender<ProtocolResponse>) -> Self {
            Self {
                response_sender,
                late_responses: Arc::default(),
                sent: Arc::default(),
                reconnects: Arc::default(),
                server: Arc::new(Mutex::new(Server::Quiet)),
                request_send_time: Arc::default(),
                query_set_send_time: Arc::default(),
            }
        }

        fn sent_query_sets(&self) -> Vec<Vec<QuerySetModification>> {
            self.sent
                .lock()
                .iter()
                .filter_map(|message| match message {
                    ClientMessage::ModifyQuerySet { modifications, .. } => {
                        Some(modifications.clone())
                    },
                    _ => None,
                })
                .collect()
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

        fn sent_mutations(&self) -> usize {
            self.sent
                .lock()
                .iter()
                .filter(|message| matches!(message, ClientMessage::Mutation { .. }))
                .count()
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
            let is_request = matches!(
                message,
                ClientMessage::Mutation { .. } | ClientMessage::Action { .. }
            );
            let is_query_set = matches!(message, ClientMessage::ModifyQuerySet { .. });
            self.sent.lock().push(message);
            if is_request {
                let send_time = *self.request_send_time.lock();
                tokio::time::sleep(send_time).await;
            }
            if is_query_set {
                let send_time = *self.query_set_send_time.lock();
                tokio::time::sleep(send_time).await;
            }
            Ok(())
        }

        async fn reconnect(&mut self, request: ReconnectRequest) {
            self.reconnects.lock().push(request.reason);
            let late_responses = std::mem::take(&mut *self.late_responses.lock());
            let server = *self.server.lock();
            let response_sender = self.response_sender.clone();
            tokio::spawn(async move {
                for response in late_responses {
                    let _ = response_sender.send(response).await;
                }
                let _ = response_sender
                    .send(ProtocolResponse::ReconnectAcknowledged)
                    .await;
                let first_response = match server {
                    Server::Quiet => return,
                    Server::RefuseAuth => auth_error(),
                    Server::AcceptAuth => ServerMessage::Transition {
                        start_version: StateVersion::initial(),
                        end_version: StateVersion {
                            ts: StateVersion::initial().ts.succ().unwrap(),
                            ..StateVersion::initial()
                        },
                        modifications: vec![],
                        client_clock_skew: None,
                        server_ts: None,
                    },
                };
                let _ = response_sender
                    .send(ProtocolResponse::ServerMessage(first_response))
                    .await;
            });
        }
    }

    fn auth_error() -> ServerMessage {
        ServerMessage::AuthError {
            error_message: "No auth provider found matching the given token".into(),
            base_version: None,
            auth_update_attempted: Some(true),
        }
    }

    struct TestWorker {
        requests: mpsc::UnboundedSender<ClientRequest>,
        reconnect_requested: Arc<Notify>,
        auth_refused: watch::Receiver<bool>,
        handle: tokio::task::JoinHandle<std::convert::Infallible>,
    }

    fn start_worker(
        protocol: &FakeProtocol,
        response_receiver: mpsc::Receiver<ProtocolResponse>,
    ) -> TestWorker {
        let (requests, request_receiver) = mpsc::unbounded_channel();
        let (watch_sender, _watch_receiver) = broadcast::channel(1);
        let reconnect_requested = Arc::new(Notify::new());
        let (auth_refused_sender, auth_refused) = watch::channel(false);
        let handle = tokio::spawn(worker(
            response_receiver,
            request_receiver,
            watch_sender,
            BaseConvexClient::new(),
            protocol.clone(),
            reconnect_requested.clone(),
            auth_refused_sender,
        ));
        TestWorker {
            requests,
            reconnect_requested,
            auth_refused,
            handle,
        }
    }

    /// Like the app's auth callback: a new token every time it's asked.
    fn changing_token() -> AuthTokenFetcher {
        let calls = Arc::new(Mutex::new(0));
        Box::new(move |_force_refresh| {
            let calls = calls.clone();
            Box::pin(async move {
                let mut calls = calls.lock();
                *calls += 1;
                Ok(AuthenticationToken::User(format!("token {calls}")))
            })
        })
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
        let worker = start_worker(&protocol, response_receiver).handle;

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
        let TestWorker {
            requests: request_sender,
            handle: worker,
            ..
        } = start_worker(&protocol, response_receiver);

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
        // Wait for the state to be resent on the new connection, then check
        // the resend left the action out.
        tokio::time::timeout(Duration::from_secs(2), async {
            while !protocol
                .sent
                .lock()
                .iter()
                .any(|message| matches!(message, ClientMessage::ModifyQuerySet { .. }))
            {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await?;
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

    #[tokio::test(start_paused = true)]
    async fn test_mutation_sent_as_the_connection_fails_is_answered_after_the_reconnect(
    ) -> anyhow::Result<()> {
        let (response_sender, response_receiver) = mpsc::channel(1);
        let protocol = FakeProtocol::new(response_sender.clone());
        *protocol.request_send_time.lock() = Duration::from_millis(100);
        *protocol.server.lock() = Server::AcceptAuth;
        let worker = start_worker(&protocol, response_receiver);
        worker
            .requests
            .send(ClientRequest::Authenticate(Some(changing_token())))?;
        protocol.wait_for_sent(1).await?;

        // While the mutation is being sent, the server refuses the token
        // and the connection fails.
        let (tx, rx) = oneshot::channel();
        worker.requests.send(ClientRequest::Mutation(
            MutationRequest {
                udf_path: UdfPath::from_str("ops:applyBatch")?,
                args: BTreeMap::new(),
            },
            tx,
        ))?;
        tokio::time::sleep(Duration::from_millis(10)).await;
        response_sender
            .send(ProtocolResponse::ServerMessage(auth_error()))
            .await?;

        // The caller still waits for the answer, and the mutation goes
        // again on the next connection, after a fresh token.
        let result = tokio::time::timeout(Duration::from_secs(2), rx)
            .await?
            .map_err(|_| anyhow::anyhow!("the caller was told the mutation failed"))?;
        tokio::time::sleep(Duration::from_secs(2)).await;
        assert_eq!(protocol.reconnects.lock().len(), 1);
        assert_eq!(protocol.sent_mutations(), 2, "{:?}", protocol.sent.lock());

        // The server runs it there and answers.
        let first = StateVersion {
            ts: StateVersion::initial().ts.succ()?,
            ..StateVersion::initial()
        };
        response_sender
            .send(ProtocolResponse::ServerMessage(
                ServerMessage::MutationResponse {
                    request_id: 0,
                    result: FunctionResult::Value(Value::from("applied")).into(),
                    ts: None,
                    log_lines: LogLinesMessage(vec![]),
                },
            ))
            .await?;
        response_sender
            .send(ProtocolResponse::ServerMessage(ServerMessage::Transition {
                start_version: first,
                end_version: StateVersion {
                    ts: first.ts.succ()?,
                    ..first
                },
                modifications: vec![],
                client_clock_skew: None,
                server_ts: None,
            }))
            .await?;
        let result = tokio::time::timeout(Duration::from_secs(2), result).await??;
        worker.handle.abort();
        assert_eq!(result, FunctionResult::Value(Value::from("applied")));
        Ok(())
    }

    #[tokio::test(start_paused = true)]
    async fn test_subscribe_sent_as_the_connection_fails_returns_the_subscription(
    ) -> anyhow::Result<()> {
        let (response_sender, response_receiver) = mpsc::channel(1);
        let protocol = FakeProtocol::new(response_sender.clone());
        *protocol.query_set_send_time.lock() = Duration::from_millis(100);
        *protocol.server.lock() = Server::AcceptAuth;
        let worker = start_worker(&protocol, response_receiver);
        worker
            .requests
            .send(ClientRequest::Authenticate(Some(changing_token())))?;
        protocol.wait_for_sent(1).await?;

        // While the subscription is being sent, the server refuses the token
        // and the connection fails.
        let (tx, rx) = oneshot::channel();
        worker.requests.send(ClientRequest::Subscribe(
            SubscribeRequest {
                udf_path: UdfPath::from_str("folders:listTree")?,
                args: BTreeMap::new(),
            },
            tx,
            worker.requests.clone(),
        ))?;
        tokio::time::sleep(Duration::from_millis(10)).await;
        response_sender
            .send(ProtocolResponse::ServerMessage(auth_error()))
            .await?;

        // The caller still gets the subscription, and the query is added
        // again on the next connection.
        let subscription = tokio::time::timeout(Duration::from_secs(2), rx)
            .await?
            .map_err(|_| anyhow::anyhow!("the caller got no subscription"))?;
        tokio::time::sleep(Duration::from_secs(2)).await;
        assert_eq!(protocol.reconnects.lock().len(), 1);
        let adds = |sets: &[Vec<QuerySetModification>]| {
            sets.iter()
                .filter(|set| matches!(set[..], [QuerySetModification::Add(_)]))
                .count()
        };
        assert_eq!(
            adds(&protocol.sent_query_sets()),
            2,
            "{:?}",
            protocol.sent.lock()
        );

        // Dropping it unsubscribes, so the query stops costing reads.
        drop(subscription);
        tokio::time::sleep(Duration::from_secs(1)).await;
        let removed = protocol
            .sent_query_sets()
            .iter()
            .any(|set| matches!(set[..], [QuerySetModification::Remove { .. }]));
        worker.handle.abort();
        assert!(removed, "{:?}", protocol.sent.lock());
        Ok(())
    }

    #[tokio::test(start_paused = true)]
    async fn test_action_sent_as_the_connection_fails_is_answered_after_the_reconnect(
    ) -> anyhow::Result<()> {
        let (response_sender, response_receiver) = mpsc::channel(1);
        let protocol = FakeProtocol::new(response_sender.clone());
        *protocol.request_send_time.lock() = Duration::from_millis(100);
        *protocol.server.lock() = Server::AcceptAuth;
        let worker = start_worker(&protocol, response_receiver);
        worker
            .requests
            .send(ClientRequest::Authenticate(Some(changing_token())))?;
        protocol.wait_for_sent(1).await?;

        // While the action is being sent, the server refuses the token and
        // the connection fails.
        let (tx, rx) = oneshot::channel();
        worker.requests.send(ClientRequest::Action(
            ActionRequest {
                udf_path: UdfPath::from_str("images:generateUploadUrl")?,
                args: BTreeMap::new(),
            },
            tx,
        ))?;
        tokio::time::sleep(Duration::from_millis(10)).await;
        response_sender
            .send(ProtocolResponse::ServerMessage(auth_error()))
            .await?;

        let result = tokio::time::timeout(Duration::from_secs(2), rx)
            .await?
            .map_err(|_| anyhow::anyhow!("the caller was told the action failed"))?;
        tokio::time::sleep(Duration::from_secs(2)).await;
        assert_eq!(protocol.reconnects.lock().len(), 1);
        assert_eq!(protocol.sent_actions(), 2, "{:?}", protocol.sent.lock());

        response_sender
            .send(ProtocolResponse::ServerMessage(
                ServerMessage::ActionResponse {
                    request_id: 0,
                    result: FunctionResult::Value(Value::from("upload url")).into(),
                    log_lines: LogLinesMessage(vec![]),
                },
            ))
            .await?;
        let result = tokio::time::timeout(Duration::from_secs(2), result).await??;
        worker.handle.abort();
        assert_eq!(result, FunctionResult::Value(Value::from("upload url")));
        Ok(())
    }

    #[tokio::test(start_paused = true)]
    async fn test_refused_token_backs_off_and_is_reported() -> anyhow::Result<()> {
        let (response_sender, response_receiver) = mpsc::channel(1);
        let protocol = FakeProtocol::new(response_sender.clone());
        *protocol.server.lock() = Server::RefuseAuth;
        let worker = start_worker(&protocol, response_receiver);
        worker
            .requests
            .send(ClientRequest::Authenticate(Some(changing_token())))?;
        response_sender
            .send(ProtocolResponse::ServerMessage(auth_error()))
            .await?;

        tokio::time::sleep(Duration::from_secs(60)).await;
        worker.handle.abort();
        // Retrying every 250 ms would be about 240 reconnects a minute. The
        // waits double from 250 ms to 15 s, which allows 8 to 12.
        let reconnects = protocol.reconnects.lock().len();
        assert!(
            (8..=12).contains(&reconnects),
            "{reconnects} reconnects in a minute"
        );
        assert!(*worker.auth_refused.borrow());
        Ok(())
    }

    /// The server refuses auth `times` times, each after the client's retry
    /// has reconnected.
    async fn refuse(
        response_sender: &mpsc::Sender<ProtocolResponse>,
        times: usize,
    ) -> anyhow::Result<()> {
        for _ in 0..times {
            response_sender
                .send(ProtocolResponse::ServerMessage(auth_error()))
                .await?;
            // Longer than the longest wait.
            tokio::time::sleep(Duration::from_secs(20)).await;
        }
        Ok(())
    }

    #[tokio::test(start_paused = true)]
    async fn test_reconnect_request_ends_the_auth_wait() -> anyhow::Result<()> {
        let (response_sender, response_receiver) = mpsc::channel(1);
        let protocol = FakeProtocol::new(response_sender.clone());
        let worker = start_worker(&protocol, response_receiver);
        worker
            .requests
            .send(ClientRequest::Authenticate(Some(changing_token())))?;
        refuse(&response_sender, 7).await?;
        assert!(*worker.auth_refused.borrow());
        // The next wait is at least 7.5 s.
        response_sender
            .send(ProtocolResponse::ServerMessage(auth_error()))
            .await?;
        tokio::time::sleep(Duration::from_millis(10)).await;
        let reconnects = protocol.reconnects.lock().len();

        // The app has a fresh token and asks for a reconnect, the way
        // ConvexClient::reconnect_now does.
        *protocol.server.lock() = Server::AcceptAuth;
        worker
            .requests
            .send(ClientRequest::Reconnect("convex_flutter:manual".into()))?;
        worker.reconnect_requested.notify_one();
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(
            protocol.reconnects.lock().len() > reconnects,
            "still waiting out the backoff"
        );
        // The server accepts the token, so it's no longer refused. (The
        // worker also reconnects once more for the request itself.)
        tokio::time::sleep(Duration::from_secs(1)).await;
        assert!(!*worker.auth_refused.borrow());
        worker.handle.abort();
        Ok(())
    }

    #[tokio::test(start_paused = true)]
    async fn test_reconnect_requested_just_before_the_wait_ends_it() -> anyhow::Result<()> {
        let (response_sender, response_receiver) = mpsc::channel(1);
        let protocol = FakeProtocol::new(response_sender.clone());
        let worker = start_worker(&protocol, response_receiver);
        worker
            .requests
            .send(ClientRequest::Authenticate(Some(changing_token())))?;
        refuse(&response_sender, 7).await?;
        let reconnects = protocol.reconnects.lock().len();

        // The app asks for a reconnect just before another refusal arrives.
        worker.reconnect_requested.notify_one();
        response_sender
            .send(ProtocolResponse::ServerMessage(auth_error()))
            .await?;
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(
            protocol.reconnects.lock().len() > reconnects,
            "still waiting out the backoff"
        );
        worker.handle.abort();
        Ok(())
    }

    #[tokio::test(start_paused = true)]
    async fn test_same_token_accepted_again_ends_the_refusal() -> anyhow::Result<()> {
        let (response_sender, response_receiver) = mpsc::channel(1);
        let protocol = FakeProtocol::new(response_sender.clone());
        let worker = start_worker(&protocol, response_receiver);
        worker
            .requests
            .send(ClientRequest::Authenticate(Some(Box::new(
                |_force_refresh| Box::pin(async { Ok(AuthenticationToken::User("token".into())) }),
            ))))?;
        refuse(&response_sender, AUTH_REFUSALS_TO_REPORT as usize).await?;
        assert!(*worker.auth_refused.borrow());

        // The server accepts the same token again (its auth config was
        // fixed, say) on the next retry.
        *protocol.server.lock() = Server::AcceptAuth;
        response_sender
            .send(ProtocolResponse::ServerMessage(auth_error()))
            .await?;
        tokio::time::sleep(Duration::from_secs(20)).await;
        assert!(!*worker.auth_refused.borrow());
        worker.handle.abort();
        Ok(())
    }

    #[tokio::test(start_paused = true)]
    async fn test_answer_without_auth_does_not_end_the_refusal() -> anyhow::Result<()> {
        let (response_sender, response_receiver) = mpsc::channel(1);
        let protocol = FakeProtocol::new(response_sender.clone());
        let token = Arc::new(Mutex::new(Some("token".to_string())));
        let callback_token = token.clone();
        let worker = start_worker(&protocol, response_receiver);
        worker
            .requests
            .send(ClientRequest::Authenticate(Some(Box::new(
                move |_force_refresh| {
                    let token = callback_token.lock().clone();
                    Box::pin(async move {
                        Ok(token.map_or(AuthenticationToken::None, AuthenticationToken::User))
                    })
                },
            ))))?;
        refuse(&response_sender, AUTH_REFUSALS_TO_REPORT as usize).await?;
        assert!(*worker.auth_refused.borrow());

        // The last retry's connection, which sent the token, drops before
        // the server answers. The callback has no token for the next one, so
        // the client reconnects without auth, and the server answers it
        // anonymously.
        *token.lock() = None;
        *protocol.server.lock() = Server::AcceptAuth;
        response_sender.send(ProtocolResponse::Failure).await?;
        tokio::time::sleep(Duration::from_secs(20)).await;
        assert!(*worker.auth_refused.borrow());
        worker.handle.abort();
        Ok(())
    }

    #[tokio::test(start_paused = true)]
    async fn test_refusals_the_next_token_ends_are_not_reported() -> anyhow::Result<()> {
        let (response_sender, response_receiver) = mpsc::channel(1);
        let protocol = FakeProtocol::new(response_sender.clone());
        // An expiring token: each refusal's retry gets a fresh token the
        // server accepts. Many refusals, but never several in a row.
        *protocol.server.lock() = Server::AcceptAuth;
        let worker = start_worker(&protocol, response_receiver);
        worker
            .requests
            .send(ClientRequest::Authenticate(Some(changing_token())))?;
        refuse(&response_sender, 2 * AUTH_REFUSALS_TO_REPORT as usize).await?;
        worker.handle.abort();
        assert!(!worker.auth_refused.has_changed()?);
        assert!(!*worker.auth_refused.borrow());
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
    reconnect_requested: &Notify,
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
                    let send_result = communicate(
                        base_client,
                        protocol_response_receiver,
                        watch_sender,
                        protocol_manager,
                        auth_recovery,
                    )
                    .await;

                    // The query stays subscribed, and is subscribed again
                    // after a reconnect, even if the connection failed during
                    // the send. Hand over the subscription either way, so the
                    // caller gets its results and dropping it unsubscribes;
                    // without it nothing could ever unsubscribe the query.
                    let watch = BroadcastStream::new(watch);
                    let subscription = QuerySubscription {
                        subscriber_id,
                        request_sender,
                        watch,
                        initial: base_client.latest_results().get(&subscriber_id).cloned(),
                    };
                    let _ = tx.send(subscription);
                    send_result?;
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
                    // From here the request is tracked, and a reconnect
                    // sends it again. Hand the caller its answer before the
                    // send below can fail, or a connection that fails during
                    // it (the server refusing auth, say) drops `tx`: the
                    // caller hears "channel closed" while the server still
                    // runs the mutation after the reconnect.
                    let result_receiver = base_client
                        .mutation(udf_path, args);
                    let _ = tx.send(result_receiver);
                    communicate(
                        base_client,
                        protocol_response_receiver,
                        watch_sender,
                        protocol_manager,
                        auth_recovery,
                    )
                    .await?;
                },
                ClientRequest::Action(action, tx) => {
                    let ActionRequest {
                        udf_path,
                        args,
                    } = action;
                    // Tracked from here, like a mutation above.
                    let result_receiver = base_client
                        .action(udf_path, args);
                    let _ = tx.send(result_receiver);
                    communicate(
                        base_client,
                        protocol_response_receiver,
                        watch_sender,
                        protocol_manager,
                        auth_recovery,
                    )
                    .await?;
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
                        auth_recovery.auth_resent = true;
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
                ClientRequest::Reconnect(reason) => {
                    // This reconnect happens now, so its wake-up must not end
                    // a later wait.
                    let _ = futures::FutureExt::now_or_never(reconnect_requested.notified());
                    return Err(reason);
                },
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
            if proves_protocol_auth && auth_recovery.auth_resent {
                // Only an answer to auth sent after the last refusal proves
                // recovery. Messages the refused connection had already sent
                // are handled before the resend, so they can't clear this.
                auth_recovery.active = false;
                auth_recovery.auth_resent = false;
                auth_recovery.refusals = 0;
                auth_recovery
                    .refused
                    .send_if_modified(|refused| std::mem::take(refused));
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
