mod frb_generated;
use std::{
    collections::{BTreeMap, HashMap},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc,
    },
};

#[cfg(debug_assertions)]
use android_logger::Config;
use async_once_cell::OnceCell;
use convex::{
    AuthTokenFetcher,
    AuthenticationToken,
    ConvexClient,
    ConvexClientBuilder,
    FunctionResult,
    SubscribedSet,
    SubscriberId,
    Value, // Convex client and result types
    WebSocketState as ConvexWebSocketState,
};
use flutter_rust_bridge::{frb, DartFnFuture};
use futures::{
    channel::oneshot::{self, Sender},
    pin_mut, select_biased, FutureExt, StreamExt,
};
use log::debug; // Logging for debugging purposes
#[cfg(debug_assertions)]
use log::LevelFilter;
use parking_lot::Mutex;
// Custom error type for Convex client operations, exposed to Dart.
#[derive(Debug, thiserror::Error)]
#[frb]
pub enum ClientError {
    /// An internal error within the mobile Convex client.
    #[error("InternalError: {msg}")]
    InternalError { msg: String },
    /// An application-specific error from a remote Convex backend function.
    #[error("ConvexError: {data}")]
    ConvexError { data: String },
    /// An unexpected server-side error from a remote Convex function.
    #[error("ServerError: {msg}")]
    ServerError { msg: String },
}

impl From<anyhow::Error> for ClientError {
    fn from(value: anyhow::Error) -> Self {
        Self::InternalError {
            msg: value.to_string(),
        }
    }
}

/// WebSocket connection state exposed to Flutter/Dart.
///
/// This enum represents the current state of the WebSocket connection
/// to the Convex backend, allowing real-time connection monitoring.
#[derive(Debug, Clone)]
#[frb]
pub enum WebSocketConnectionState {
    /// The WebSocket is open and connected to the Convex backend.
    Connected,
    /// The WebSocket is closed and is connecting or reconnecting.
    Connecting,
}

impl From<ConvexWebSocketState> for WebSocketConnectionState {
    fn from(state: ConvexWebSocketState) -> Self {
        match state {
            ConvexWebSocketState::Connected => WebSocketConnectionState::Connected,
            ConvexWebSocketState::Connecting => WebSocketConnectionState::Connecting,
        }
    }
}

/// Trait defining the interface for handling subscription updates.
// Not directly exposed to Dart, used internally by subscribers.
pub trait QuerySubscriber: Send + Sync {
    fn on_update(&self, value: String); // Called when a new update is received
    fn on_error(&self, message: String, value: Option<String>); // Called on error with optional value
}

/// Adapter struct to implement QuerySubscriber using Dart callbacks.
pub struct CallbackSubscriber {
    on_update: Box<dyn Fn(String) + Send + Sync>, // Callback for updates
    on_error: Box<dyn Fn(String, Option<String>) + Send + Sync>, // Callback for errors
}

impl QuerySubscriber for CallbackSubscriber {
    fn on_update(&self, value: String) {
        (self.on_update)(value);
    }

    fn on_error(&self, message: String, value: Option<String>) {
        (self.on_error)(message, value);
    }
}

/// Opaque type for Dart, representing a subscription handle with cancellation.
#[frb(opaque)]
pub struct SubscriptionHandle {
    cancel_sender: Arc<Mutex<Option<Sender<()>>>>, // Sender to cancel the subscription
}

impl SubscriptionHandle {
    fn new(cancel_sender: Sender<()>) -> Self {
        SubscriptionHandle {
            cancel_sender: Arc::new(Mutex::new(Some(cancel_sender))),
        }
    }

    /// Cancels the subscription by sending a cancellation signal.
    #[frb(sync)]
    pub fn cancel(&self) {
        if let Some(sender) = self.cancel_sender.lock().take() {
            sender.send(()).unwrap();
        }
    }
}

/// Opaque type for Dart, representing an auth session handle with lifecycle management.
/// Used to control the token refresh loop and check authentication state.
#[frb(opaque)]
pub struct AuthHandle {
    cancel_sender: Arc<Mutex<Option<Sender<()>>>>,
    is_authenticated: Arc<AtomicBool>,
}

impl AuthHandle {
    fn new(cancel_sender: Sender<()>, is_authenticated: Arc<AtomicBool>) -> Self {
        AuthHandle {
            cancel_sender: Arc::new(Mutex::new(Some(cancel_sender))),
            is_authenticated,
        }
    }

    /// Disposes the auth session, stopping the token refresh loop and clearing authentication.
    #[frb(sync)]
    pub fn dispose(&self) {
        if let Some(sender) = self.cancel_sender.lock().take() {
            let _ = sender.send(());
        }
    }

    /// Returns whether the user is currently authenticated.
    #[frb(sync)]
    pub fn is_authenticated(&self) -> bool {
        self.is_authenticated.load(Ordering::SeqCst)
    }
}

/// One query of a group subscribed together (see
/// [MobileConvexClient::subscribe_group]).
#[frb]
pub struct GroupQuery {
    pub name: String,
    pub args: HashMap<String, String>,
}

/// Where a group's queries stand in one set of results.
#[derive(Debug, PartialEq)]
enum GroupStep {
    /// Some query has no result yet.
    Waiting,
    /// Some query failed: its message, and its ConvexError data as JSON.
    Failed(String, Option<String>),
    /// Every query has a value. Holds the values, and what to send for
    /// each: its JSON, or None where it is the same as last sent.
    Answered(Vec<FunctionResult>, Vec<Option<String>>),
}

/// Where the queries [ids] stand, given each one's result ([result_of]) and
/// the values last sent ([sent]). A failure anywhere outranks a query still
/// waiting, so an error shows as soon as it is known.
fn group_step<'a, K>(
    ids: &[K],
    result_of: impl Fn(&K) -> Option<&'a FunctionResult>,
    sent: Option<&[FunctionResult]>,
) -> GroupStep {
    let results: Vec<Option<&FunctionResult>> = ids.iter().map(result_of).collect();
    for result in results.iter().flatten() {
        match result {
            FunctionResult::ErrorMessage(message) => {
                return GroupStep::Failed(message.clone(), None);
            }
            FunctionResult::ConvexError(error) => {
                return GroupStep::Failed(
                    error.message.clone(),
                    Some(
                        serde_json::to_string(&serde_json::Value::from(error.data.clone()))
                            .unwrap(),
                    ),
                );
            }
            FunctionResult::Value(_) => {}
        }
    }
    let Some(values) = results
        .into_iter()
        .map(|result| result.cloned())
        .collect::<Option<Vec<_>>>()
    else {
        return GroupStep::Waiting;
    };
    let payload = values
        .iter()
        .enumerate()
        .map(|(index, result)| match (sent, result) {
            (Some(sent), _) if sent[index] == *result => None,
            (_, FunctionResult::Value(value)) => {
                Some(serde_json::to_string(&serde_json::Value::from(value.clone())).unwrap())
            }
            _ => unreachable!("failures return above"),
        })
        .collect();
    GroupStep::Answered(values, payload)
}

/// Adapter for Dart functions as subscribers, handling async callbacks.
pub struct CallbackSubscriberDartFn {
    on_update: Box<dyn Fn(String) -> DartFnFuture<()> + Send + Sync>, // Async update callback
    on_error: Box<dyn Fn(String, Option<String>) -> DartFnFuture<()> + Send + Sync>, // Async error callback
}

impl QuerySubscriber for CallbackSubscriberDartFn {
    fn on_update(&self, value: String) {
        let future = (self.on_update)(value);
        tokio::spawn(async move {
            let _ = future.await; // Await the future, ignoring the result
        });
    }

    fn on_error(&self, message: String, value: Option<String>) {
        let future = (self.on_error)(message, value);
        tokio::spawn(async move {
            let _ = future.await;
        });
    }
}

/// Main Convex client struct, opaque to Dart, managing connections and operations.
#[frb(opaque)]
pub struct MobileConvexClient {
    deployment_url: String,         // URL of the Convex deployment
    client_id: String,              // Client ID for authentication
    client: OnceCell<ConvexClient>, // Lazy-initialized Convex client
    rt: tokio::runtime::Runtime,    // Tokio runtime for async operations
    auth_generation: Arc<AtomicU64>,
    // Channel sender for WebSocket state change notifications
    state_change_sender: Arc<Mutex<Option<tokio::sync::mpsc::Sender<ConvexWebSocketState>>>>,
}

impl MobileConvexClient {
    /// Creates a new MobileConvexClient instance with the given deployment URL and client ID.
    #[frb(sync)]
    pub fn new(deployment_url: String, client_id: String) -> MobileConvexClient {
        #[cfg(debug_assertions)]
        android_logger::init_once(Config::default().with_max_level(LevelFilter::Error));
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .unwrap();
        MobileConvexClient {
            deployment_url,
            client_id,
            client: OnceCell::new(),
            rt,
            auth_generation: Arc::new(AtomicU64::new(0)),
            state_change_sender: Arc::new(Mutex::new(None)),
        }
    }

    /// Sets up WebSocket connection state change listener.
    ///
    /// Must be called BEFORE any queries/mutations to capture all state changes.
    /// The callback will be invoked whenever the WebSocket transitions between
    /// Connected and Connecting states.
    ///
    /// # Arguments
    ///
    /// * `on_state_change` - Async callback invoked when connection state changes
    ///
    /// # Example
    ///
    /// ```dart
    /// await client.onWebsocketStateChange(
    ///   onStateChange: (state) async {
    ///     print('Connection state: ${state.name}');
    ///   },
    /// );
    /// ```
    #[frb]
    pub async fn on_websocket_state_change(
        &self,
        on_state_change: impl Fn(WebSocketConnectionState) -> DartFnFuture<()> + Send + Sync + 'static,
    ) -> Result<(), ClientError> {
        println!("RUST: on_websocket_state_change() called");

        // Create tokio mpsc channel for receiving state changes from convex client
        let (state_tx, mut state_rx) = tokio::sync::mpsc::channel::<ConvexWebSocketState>(10);
        println!("RUST: Created mpsc channel for state changes");

        // Store sender for use when initializing the client
        {
            let mut sender = self.state_change_sender.lock();
            *sender = Some(state_tx);
            println!("RUST: Stored state_tx in state_change_sender");
        }

        // Spawn task to listen for state changes and call Dart callback
        let on_state_change = Arc::new(on_state_change);
        println!("RUST: Spawning listener task for state changes");
        self.rt.spawn(async move {
            println!("RUST: Listener task started, waiting for state changes");
            while let Some(state) = state_rx.recv().await {
                println!("RUST: Received state change from channel: {:?}", state);
                let dart_state = WebSocketConnectionState::from(state);
                println!("RUST: Converted to Dart state: {:?}", dart_state);
                let callback = on_state_change.clone();
                let future = (callback)(dart_state);
                println!("RUST: Calling Dart callback");
                let _ = future.await;
                println!("RUST: Dart callback completed");
            }
            println!("RUST: Listener task exiting (channel closed)");
        });

        println!("RUST: on_websocket_state_change() returning");
        Ok(())
    }

    /// Retrieves or initializes a connected Convex client.
    async fn connected_client(&self) -> anyhow::Result<ConvexClient> {
        let url = self.deployment_url.clone();
        let state_sender = self.state_change_sender.lock().clone();

        println!(
            "RUST: connected_client() called with sender: {:?}",
            state_sender.is_some()
        );

        self.client
            .get_or_try_init(async {
                let client_id = self.client_id.to_owned();

                // Build client directly without spawning a task
                // This ensures callback is registered BEFORE connection starts
                println!("RUST: Building ConvexClient directly (no task spawn)");
                let mut builder = ConvexClientBuilder::new(url.as_str()).with_client_id(&client_id);

                // Register state change callback BEFORE building
                if let Some(sender) = state_sender {
                    println!("RUST: Registering state change callback with builder");
                    builder = builder.with_on_state_change(sender);
                } else {
                    println!(
                        "RUST WARNING: No sender available - state changes will not be emitted"
                    );
                }

                println!("RUST: Calling builder.build() - connection will start now");
                let result = builder.build().await;
                match &result {
                    Ok(_) => println!("RUST: ConvexClient built successfully"),
                    Err(e) => println!("RUST ERROR: Failed to build ConvexClient: {:?}", e),
                }
                result
            })
            .await
            .map(|client_ref| client_ref.clone())
    }

    /// Executes a query on the Convex backend.
    #[frb]
    pub async fn query(
        &self,
        name: String,
        args: HashMap<String, String>,
    ) -> Result<String, ClientError> {
        let mut client = self.connected_client().await?;
        debug!("got the client");
        let result = client.query(name.as_str(), parse_json_args(args)).await?;
        debug!("got the result");
        handle_direct_function_result(result)
    }

    /// Subscribes to real-time updates from a Convex query.
    #[frb]
    pub async fn subscribe(
        &self,
        name: String,
        args: HashMap<String, String>,
        on_update: impl Fn(String) -> DartFnFuture<()> + Send + Sync + 'static,
        on_error: impl Fn(String, Option<String>) -> DartFnFuture<()> + Send + Sync + 'static,
    ) -> Result<SubscriptionHandle, ClientError> {
        let subscriber = Arc::new(CallbackSubscriberDartFn {
            on_update: Box::new(on_update),
            on_error: Box::new(on_error),
        });
        self.internal_subscribe(name, args, subscriber)
            .await
            .map_err(Into::into)
    }

    /// Subscribes to [queries] together, so their values always come from one
    /// server state: separate subscriptions can each answer from a different
    /// one, and a page read in parts would then show a state the server never
    /// had.
    ///
    /// [on_update] gets every query's value at once, first when all of them
    /// have one, then each time the server answers again. A value is JSON, or
    /// None where it is the same as in the last update. [on_error] gets the
    /// failure when any query fails; the next update after it sends every
    /// value. Updates arrive in order, each after the last one's callback
    /// returned.
    #[frb]
    pub async fn subscribe_group(
        &self,
        queries: Vec<GroupQuery>,
        on_update: impl Fn(Vec<Option<String>>) -> DartFnFuture<()> + Send + Sync + 'static,
        on_error: impl Fn(String, Option<String>) -> DartFnFuture<()> + Send + Sync + 'static,
    ) -> Result<SubscriptionHandle, ClientError> {
        let mut client = self.connected_client().await?;
        let SubscribedSet {
            subscriptions,
            results,
            mut updates,
        } = client
            .subscribe_set(
                queries
                    .into_iter()
                    .map(|query| (query.name, parse_json_args(query.args)))
                    .collect(),
            )
            .await?;
        let (cancel_sender, cancel_receiver) = oneshot::channel::<()>();
        self.rt.spawn(async move {
            let ids: Vec<SubscriberId> = subscriptions.iter().map(|query| *query.id()).collect();
            let mut sent: Option<Vec<FunctionResult>> = None;
            let mut latest = Some(results);
            let cancel_fut = cancel_receiver.fuse();
            pin_mut!(cancel_fut);
            loop {
                if let Some(results) = latest.take() {
                    match group_step(&ids, |id| results.get(id), sent.as_deref()) {
                        GroupStep::Waiting => {}
                        GroupStep::Failed(message, data) => {
                            sent = None;
                            on_error(message, data).await;
                        }
                        GroupStep::Answered(values, payload) => {
                            on_update(payload).await;
                            sent = Some(values);
                        }
                    }
                }
                select_biased! {
                    _ = cancel_fut => break,
                    update = updates.next().fuse() => match update {
                        Some(results) => latest = Some(results),
                        None => {
                            log::warn!("Group subscription stream ended");
                            break;
                        }
                    },
                }
            }
            // Dropping the tokens unsubscribes every query.
            drop(subscriptions);
            debug!("Group subscription canceled");
        });
        Ok(SubscriptionHandle::new(cancel_sender))
    }

    /// Internal method for subscription logic.
    async fn internal_subscribe(
        &self,
        name: String,
        args: HashMap<String, String>,
        subscriber: Arc<dyn QuerySubscriber>,
    ) -> anyhow::Result<SubscriptionHandle> {
        let mut client = self.connected_client().await?;
        debug!("New subscription");
        let mut subscription = client
            .subscribe(name.as_str(), parse_json_args(args))
            .await?;
        let (cancel_sender, cancel_receiver) = oneshot::channel::<()>();
        self.rt.spawn(async move {
            let cancel_fut = cancel_receiver.fuse();
            pin_mut!(cancel_fut);
            loop {
                select_biased! {
                    new_val = subscription.next().fuse() => {
                        let new_val = match new_val {
                            Some(val) => val,
                            None => {
                                log::warn!("Subscription stream ended for {}", &name);
                                break;
                            }
                        };
                        match new_val {
                            FunctionResult::Value(value) => {
                                debug!("Updating with {value:?}");
                                subscriber.on_update(serde_json::to_string(
                                    &serde_json::Value::from(value),
                                ).unwrap());
                            }
                            FunctionResult::ErrorMessage(message) => {
                                subscriber.on_error(message, None);
                            }
                            FunctionResult::ConvexError(error) => subscriber.on_error(
                                error.message,
                                Some(serde_json::ser::to_string(
                                    &serde_json::Value::from(error.data),
                                ).unwrap()),
                            ),
                        }
                    }
                    _ = cancel_fut => {
                        break;
                    }
                }
            }
            debug!("Subscription canceled");
        });
        Ok(SubscriptionHandle::new(cancel_sender))
    }

    /// Executes a mutation on the Convex backend.
    #[frb]
    pub async fn mutation(
        &self,
        name: String,
        args: HashMap<String, String>,
    ) -> Result<String, ClientError> {
        let result = self.internal_mutation(name, args).await?;
        handle_direct_function_result(result)
    }

    /// Internal method for mutation logic.
    async fn internal_mutation(
        &self,
        name: String,
        args: HashMap<String, String>,
    ) -> anyhow::Result<FunctionResult> {
        let mut client = self.connected_client().await?;
        self.rt
            .spawn(async move { client.mutation(&name, parse_json_args(args)).await })
            .await?
    }

    /// Executes an action on the Convex backend.
    #[frb]
    pub async fn action(
        &self,
        name: String,
        args: HashMap<String, String>,
    ) -> Result<String, ClientError> {
        debug!("Running action: {}", name);
        let result = self.internal_action(name, args).await?;
        debug!("Got action result: {:?}", result);
        handle_direct_function_result(result)
    }

    /// Internal method for action logic.
    async fn internal_action(
        &self,
        name: String,
        args: HashMap<String, String>,
    ) -> anyhow::Result<FunctionResult> {
        let mut client = self.connected_client().await?;
        debug!("Running action: {}", name);
        self.rt
            .spawn(async move { client.action(&name, parse_json_args(args)).await })
            .await?
    }

    /// Sets authentication token for the client.
    #[frb]
    pub async fn set_auth(&self, token: Option<String>) -> Result<(), ClientError> {
        Ok(self.internal_set_auth(token).await?)
    }

    /// Internal method for setting authentication.
    async fn internal_set_auth(&self, token: Option<String>) -> anyhow::Result<()> {
        // Invalidate any older refresh handle before replacing its callback.
        // A delayed disposal from that handle must not clear this auth state.
        self.auth_generation.fetch_add(1, Ordering::SeqCst);
        let mut client = self.connected_client().await?;
        self.rt
            .spawn(async move { client.set_auth(token).await })
            .await
            .map_err(|e| e.into())
    }

    /// Forces a WebSocket reconnect while retaining current client state.
    #[frb]
    pub async fn reconnect_now(&self, reason: String) -> Result<(), ClientError> {
        let mut client = self.connected_client().await?;
        self.rt
            .spawn(async move { client.reconnect_now(&reason).await })
            .await
            .map_err(|e| ClientError::InternalError { msg: e.to_string() })?;
        Ok(())
    }

    /// Sets authentication with token refresh on every WebSocket reconnect.
    ///
    /// The callback is owned by the upstream Convex client so authentication
    /// and query state are replayed together after a disconnect.
    ///
    /// Returns an AuthHandle that can be used to dispose the auth session.
    #[frb]
    pub async fn set_auth_with_refresh(
        &self,
        fetch_token: impl Fn() -> DartFnFuture<Option<String>> + Send + Sync + 'static,
        on_auth_change: impl Fn(bool) -> DartFnFuture<()> + Send + Sync + 'static,
    ) -> Result<AuthHandle, ClientError> {
        let is_authenticated = Arc::new(AtomicBool::new(false));
        let (cancel_sender, cancel_receiver) = oneshot::channel::<()>();
        let generation = self.auth_generation.fetch_add(1, Ordering::SeqCst) + 1;

        let mut client = self.connected_client().await?;
        let fetch_token = Arc::new(fetch_token);
        let on_auth_change = Arc::new(on_auth_change);
        let cancel_on_auth_change = on_auth_change.clone();
        let callback_is_authenticated = is_authenticated.clone();
        let callback: AuthTokenFetcher = Box::new(move |_force_refresh| {
            let fetch_token = fetch_token.clone();
            let on_auth_change = on_auth_change.clone();
            let is_authenticated = callback_is_authenticated.clone();
            Box::pin(async move {
                let token = (fetch_token)().await;
                let next_is_authenticated = token.is_some();
                let changed = is_authenticated.swap(next_is_authenticated, Ordering::SeqCst)
                    != next_is_authenticated;
                if changed {
                    let _ = (on_auth_change)(next_is_authenticated).await;
                }
                Ok(match token {
                    Some(token) => AuthenticationToken::User(token),
                    None => AuthenticationToken::None,
                })
            })
        });
        client.set_auth_callback(Some(callback)).await;

        let cancel_is_authenticated = is_authenticated.clone();
        let cancel_auth_generation = self.auth_generation.clone();
        self.rt.spawn(async move {
            let _ = cancel_receiver.await;
            if cancel_auth_generation
                .compare_exchange(
                    generation,
                    generation + 1,
                    Ordering::SeqCst,
                    Ordering::SeqCst,
                )
                .is_err()
            {
                return;
            }
            let mut client = client.clone();
            client.set_auth_callback(None).await;
            if cancel_is_authenticated.swap(false, Ordering::SeqCst) {
                let _ = (cancel_on_auth_change)(false).await;
            }
        });

        Ok(AuthHandle::new(cancel_sender, is_authenticated))
    }
}

/// Utility function to parse HashMap arguments into Convex Value format.
fn parse_json_args(raw_args: HashMap<String, String>) -> BTreeMap<String, Value> {
    raw_args
        .into_iter()
        .map(|(k, v)| {
            (
                k,
                Value::try_from(
                    serde_json::from_str::<serde_json::Value>(&v)
                        .expect("Invalid JSON data from FFI"),
                )
                .expect("Invalid Convex data from FFI"),
            )
        })
        .collect()
}

/// Utility function to handle and serialize FunctionResult into a string or error.
fn handle_direct_function_result(result: FunctionResult) -> Result<String, ClientError> {
    match result {
        FunctionResult::Value(v) => serde_json::to_string(&serde_json::Value::from(v))
            .map_err(|e| ClientError::InternalError { msg: e.to_string() }),
        FunctionResult::ConvexError(e) => Err(ClientError::ConvexError {
            data: serde_json::ser::to_string(&serde_json::Value::from(e.data)).unwrap(),
        }),
        FunctionResult::ErrorMessage(msg) => Err(ClientError::ServerError { msg }),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use convex::{ConvexError, FunctionResult, Value};

    use super::{group_step, GroupStep};

    fn value(text: &str) -> FunctionResult {
        FunctionResult::Value(Value::from(text))
    }

    fn step(results: &HashMap<u32, FunctionResult>, sent: Option<&[FunctionResult]>) -> GroupStep {
        group_step(&[1, 2], |id| results.get(id), sent)
    }

    #[test]
    fn waits_until_every_query_has_a_value() {
        let results = HashMap::from([(1, value("a"))]);
        assert_eq!(step(&results, None), GroupStep::Waiting);
    }

    #[test]
    fn first_answer_sends_every_value() {
        let results = HashMap::from([(1, value("a")), (2, value("b"))]);
        assert_eq!(
            step(&results, None),
            GroupStep::Answered(
                vec![value("a"), value("b")],
                vec![Some("\"a\"".to_string()), Some("\"b\"".to_string())],
            ),
        );
    }

    #[test]
    fn later_answers_send_only_changed_values() {
        let results = HashMap::from([(1, value("a")), (2, value("c"))]);
        assert_eq!(
            step(&results, Some(&[value("a"), value("b")])),
            GroupStep::Answered(
                vec![value("a"), value("c")],
                vec![None, Some("\"c\"".to_string())]
            ),
        );
        // An answer that changes nothing still arrives, as a single
        // subscription's does.
        assert_eq!(
            step(&results, Some(&[value("a"), value("c")])),
            GroupStep::Answered(vec![value("a"), value("c")], vec![None, None]),
        );
    }

    #[test]
    fn a_failure_outranks_a_query_still_waiting() {
        let results = HashMap::from([(
            2,
            FunctionResult::ConvexError(ConvexError {
                message: "denied".to_string(),
                data: Value::from("ACCESS_DENIED"),
            }),
        )]);
        assert_eq!(
            step(&results, None),
            GroupStep::Failed("denied".to_string(), Some("\"ACCESS_DENIED\"".to_string())),
        );
        let results = HashMap::from([
            (1, value("a")),
            (2, FunctionResult::ErrorMessage("boom".to_string())),
        ]);
        assert_eq!(
            step(&results, None),
            GroupStep::Failed("boom".to_string(), None)
        );
    }
}
