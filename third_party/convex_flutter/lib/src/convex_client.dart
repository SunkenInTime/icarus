import 'dart:async';

import 'package:convex_flutter/src/impl/convex_client_interface.dart';
import 'package:convex_flutter/src/impl/convex_client_factory.dart';
import 'package:convex_flutter/src/rust/lib.dart' show WebSocketConnectionState, SubscriptionHandle, AuthHandle;
import 'package:convex_flutter/src/connection_status.dart';
import 'package:convex_flutter/src/convex_config.dart';
import 'package:convex_flutter/src/app_lifecycle_event.dart';

/// Callback type for fetching authentication tokens.
/// Should return a JWT token string, or null to sign out.
typedef TokenFetcher = Future<String?> Function();

/// Callback type for authentication state changes.
typedef AuthStateCallback = void Function(bool isAuthenticated);

/// A client for interacting with a Convex backend service.
///
/// The ConvexClient provides methods for executing queries, mutations, actions and
/// managing real-time subscriptions with a Convex backend.
///
/// This client automatically selects the appropriate implementation based on platform:
/// - **Mobile/Desktop** (Android, iOS, macOS, Windows, Linux): Uses FFI + Rust SDK
/// - **Web**: Uses pure Dart WebSocket implementation (no Rust required)
///
/// Example usage:
///
/// ```dart
/// // Initialize the client
/// await ConvexClient.initialize(
///   ConvexConfig(
///     deploymentUrl: "https://my-app.convex.cloud",
///     clientId: "flutter-app-1.0",
///   ),
/// );
///
/// // Execute a query
/// final result = await ConvexClient.instance.query(
///   "messages:list",
///   {"limit": "10"}
/// );
///
/// // Subscribe to real-time updates
/// final subscription = await ConvexClient.instance.subscribe(
///   name: "messages:list",
///   args: {},
///   onUpdate: (value) {
///     print("New messages: $value");
///   },
///   onError: (message, value) {
///     print("Error: $message");
///   }
/// );
///
/// // Execute a mutation
/// await ConvexClient.instance.mutation(
///   name: "messages:send",
///   args: {
///     "body": "Hello!",
///     "author": "User123"
///   }
/// );
///
/// // Cancel subscription when done
/// subscription.cancel();
/// ```
class ConvexClient {
  /// Private static instance for singleton pattern
  static ConvexClient? _instance;

  /// The platform-specific implementation (Native or Web)
  final IConvexClient _impl;

  /// Private constructor
  ConvexClient._(this._impl);

  /// Public getter to access singleton instance
  /// Throws StateError if accessed before initialization
  static ConvexClient get instance {
    if (_instance == null) {
      throw StateError(
        'ConvexClient not initialized. '
        'Call ConvexClient.initialize() first.',
      );
    }
    return _instance!;
  }

  /// Initializes the ConvexClient singleton instance with configuration.
  ///
  /// This method must be called once before accessing [instance].
  /// Subsequent calls will throw a StateError.
  ///
  /// The client automatically selects the appropriate platform implementation:
  /// - **Web**: Pure Dart WebSocket (no Rust required)
  /// - **Mobile/Desktop**: FFI + Rust SDK (requires Rust toolchain for building)
  ///
  /// Example usage:
  /// ```dart
  /// await ConvexClient.initialize(
  ///   ConvexConfig(
  ///     deploymentUrl: "https://your-app.convex.cloud",
  ///     clientId: "flutter-app",
  ///     operationTimeout: Duration(seconds: 30),
  ///   ),
  /// );
  /// ```
  static Future<void> initialize(ConvexConfig config) async {
    if (_instance != null) {
      throw StateError('ConvexClient already initialized');
    }

    // Create platform-specific implementation using factory
    // Factory automatically selects:
    // - WebConvexClient (pure Dart) on web
    // - NativeConvexClient (FFI + Rust SDK) on native platforms
    final IConvexClient impl = await createPlatformClient(config);

    // Create singleton with chosen implementation
    _instance = ConvexClient._(impl);
  }

  /// Initializes the ConvexClient singleton instance (DEPRECATED).
  ///
  /// This method is deprecated. Use [initialize] with [ConvexConfig] instead.
  ///
  /// Example migration:
  /// ```dart
  /// // Old way (deprecated)
  /// await ConvexClient.init(deploymentUrl: "...", clientId: "...");
  ///
  /// // New way
  /// await ConvexClient.initialize(
  ///   ConvexConfig(deploymentUrl: "...", clientId: "..."),
  /// );
  /// ```
  @Deprecated('Use initialize(ConvexConfig) instead')
  static Future<ConvexClient> init({
    required String deploymentUrl,
    required String clientId,
  }) async {
    if (_instance == null) {
      await initialize(
        ConvexConfig(
          deploymentUrl: deploymentUrl,
          clientId: clientId,
        ),
      );
    }
    return _instance!;
  }

  // ============================================================================
  // Public API - All methods delegate to platform-specific implementation
  // ============================================================================

  /// Configuration for this client instance
  ConvexConfig get config => _impl.config;

  /// Executes a Convex query operation with timeout.
  ///
  /// [name] - Name of the query function to execute (e.g., "messages:list")
  /// [args] - Map of arguments to pass to the query
  ///
  /// Returns the query result as a JSON string.
  /// Throws [TimeoutException] if the operation exceeds [config.operationTimeout].
  Future<String> query(String name, Map<String, dynamic> args) =>
      _impl.query(name, args);

  /// Executes a Convex mutation operation with timeout.
  ///
  /// [name] - Name of the mutation function to execute
  /// [args] - Map of arguments to pass to the mutation
  ///
  /// Returns the mutation result as a JSON string.
  /// Throws [TimeoutException] if the operation exceeds [config.operationTimeout].
  Future<String> mutation({
    required String name,
    required Map<String, dynamic> args,
  }) =>
      _impl.mutation(name: name, args: args);

  /// Executes a Convex action operation with timeout.
  ///
  /// [name] - Name of the action function to execute
  /// [args] - Map of arguments to pass to the action
  ///
  /// Returns the action result as a JSON string.
  /// Throws [TimeoutException] if the operation exceeds [config.operationTimeout].
  Future<String> action({
    required String name,
    required Map<String, dynamic> args,
  }) =>
      _impl.action(name: name, args: args);

  /// Creates a real-time subscription to a Convex query.
  ///
  /// [name] - Name of the query function to subscribe to
  /// [args] - Map of arguments for the subscription
  /// [onUpdate] - Callback function called when new data arrives
  /// [onError] - Callback function called when an error occurs
  ///
  /// Returns a handle that can be used to cancel the subscription.
  Future<SubscriptionHandle> subscribe({
    required String name,
    required Map<String, dynamic> args,
    required void Function(String) onUpdate,
    required void Function(String, String?) onError,
  }) =>
      _impl.subscribe(
        name: name,
        args: args,
        onUpdate: onUpdate,
        onError: onError,
      );

  // ============================================================================
  // Authentication API
  // ============================================================================

  /// Sets the authentication token for the client (simple/static).
  ///
  /// Use this for simple auth scenarios where you manage token refresh externally.
  /// For automatic token refresh, use [setAuthWithRefresh] instead.
  ///
  /// [token] - The authentication token to set, or null to clear auth.
  ///
  /// Example usage:
  /// ```dart
  /// // Set auth with a token
  /// await client.setAuth(token: 'eyJhbGciOiJSUzI1NiIs...');
  ///
  /// // Clear auth
  /// await client.setAuth(token: null);
  /// ```
  Future<void> setAuth({required String? token}) => _impl.setAuth(token: token);

  /// Sets up authentication with automatic token refresh.
  ///
  /// This is the recommended way to handle authentication. The [fetchToken]
  /// callback will be called:
  /// - Immediately to get the initial token
  /// - Automatically when the token is about to expire (60 seconds before)
  ///
  /// Example usage:
  /// ```dart
  /// final authHandle = await client.setAuthWithRefresh(
  ///   fetchToken: () async {
  ///     // Get token from your auth provider (Clerk, Auth0, Firebase, etc.)
  ///     return await FirebaseAuth.instance.currentUser?.getIdToken();
  ///   },
  ///   onAuthChange: (isAuthenticated) {
  ///     print('Auth state changed: $isAuthenticated');
  ///   },
  /// );
  ///
  /// // Later, when signing out:
  /// authHandle.dispose();
  /// ```
  ///
  /// [fetchToken] - Async function that returns a JWT token, or null to sign out.
  /// [onAuthChange] - Optional callback invoked when auth state changes.
  ///
  /// Returns an [AuthHandleWrapper] that can be used to dispose the auth session.
  Future<AuthHandleWrapper> setAuthWithRefresh({
    required TokenFetcher fetchToken,
    AuthStateCallback? onAuthChange,
  }) async {
    final handle = await _impl.setAuthWithRefresh(
      tokenFetcher: fetchToken,
      onAuthChange: onAuthChange,
    );
    return AuthHandleWrapper._(handle);
  }

  /// Clears authentication and disposes any active auth refresh loop.
  ///
  /// This will:
  /// - Stop any running token refresh loop
  /// - Clear the auth token from the Convex client
  /// - Emit `false` on the [authState] stream
  Future<void> clearAuth() => _impl.clearAuth();

  /// Stream of authentication state changes.
  /// Emits `true` when authenticated, `false` when not.
  ///
  /// Example usage:
  /// ```dart
  /// ConvexClient.instance.authState.listen((isAuthenticated) {
  ///   setState(() => _isLoggedIn = isAuthenticated);
  /// });
  /// ```
  Stream<bool> get authState => _impl.authState;

  /// Current authentication state (synchronous).
  /// Returns `true` if authenticated via [setAuthWithRefresh], `false` otherwise.
  bool get isAuthenticated => _impl.isAuthenticated;

  // ============================================================================
  // Connection Management API
  // ============================================================================

  /// Stream of WebSocket connection state changes.
  ///
  /// Emits state whenever the underlying WebSocket connection changes
  /// between Connected and Connecting states. This provides real-time
  /// connection monitoring without manual polling.
  ///
  /// Example usage:
  /// ```dart
  /// ConvexClient.instance.connectionState.listen((state) {
  ///   if (state == WebSocketConnectionState.connected) {
  ///     print('Connected to Convex!');
  ///   }
  /// });
  /// ```
  Stream<WebSocketConnectionState> get connectionState => _impl.connectionState;

  /// Current WebSocket connection state (synchronous).
  /// Returns the most recent state from the WebSocket connection.
  WebSocketConnectionState get currentConnectionState =>
      _impl.currentConnectionState;

  /// Convenience getter - returns true if WebSocket is currently connected.
  bool get isConnected => _impl.isConnected;

  /// Manually checks the connection status to the Convex backend.
  ///
  /// **DEPRECATED:** Use the [connectionState] stream for real-time state tracking.
  /// This method is slower and less accurate than the WebSocket state stream.
  ///
  /// This method uses the [ConvexConfig.healthCheckQuery] to verify connectivity.
  /// If no health check query is configured, throws a [StateError].
  ///
  /// Returns [ConnectionStatus.connected] if the connection is working,
  /// [ConnectionStatus.timeout] if the check times out, or
  /// [ConnectionStatus.error] if an error occurs.
  ///
  /// Example usage (deprecated):
  /// ```dart
  /// final status = await ConvexClient.instance.checkConnection();
  /// if (status == ConnectionStatus.connected) {
  ///   print('Connected!');
  /// }
  /// ```
  ///
  /// Recommended alternative - use the real-time connection state stream:
  /// ```dart
  /// ConvexClient.instance.connectionState.listen((state) {
  ///   if (state == WebSocketConnectionState.connected) {
  ///     print('Connected!');
  ///   }
  /// });
  /// ```
  @Deprecated('Use connectionState stream for real-time connection monitoring')
  Future<ConnectionStatus> checkConnection() => _impl.checkConnection();

  /// Attempts to reconnect to the Convex backend.
  ///
  /// This method calls [checkConnection] and returns true if the
  /// connection check succeeds, false otherwise.
  ///
  /// Typically called after the app resumes from background or
  /// after detecting a network interruption.
  ///
  /// Example usage:
  /// ```dart
  /// ConvexClient.instance.lifecycleEvents.listen((event) {
  ///   if (event == AppLifecycleEvent.resumed) {
  ///     final connected = await ConvexClient.instance.reconnect();
  ///     if (connected) {
  ///       print('Reconnected successfully');
  ///     }
  ///   }
  /// });
  /// ```
  Future<bool> reconnect() => _impl.reconnect();

  // ============================================================================
  // Lifecycle Management API
  // ============================================================================

  /// Stream of app lifecycle events (foreground/background transitions).
  ///
  /// Emits events when the app transitions between foreground/background states.
  /// Useful for handling reconnection or other lifecycle-based logic.
  ///
  /// Example usage:
  /// ```dart
  /// ConvexClient.instance.lifecycleEvents.listen((event) {
  ///   if (event == AppLifecycleEvent.resumed) {
  ///     // App came to foreground
  ///     ConvexClient.instance.reconnect();
  ///   }
  /// });
  /// ```
  Stream<AppLifecycleEvent> get lifecycleEvents => _impl.lifecycleEvents;

  // ============================================================================
  // Resource Management
  // ============================================================================

  /// Dispose the client and clean up resources.
  ///
  /// Call this when you're done using the client to free up resources.
  /// Note: This is typically not needed as the client is a singleton,
  /// but can be useful in testing scenarios.
  void dispose() => _impl.dispose();
}

/// Wrapper for auth handle providing Dart-friendly API.
///
/// Returned by [ConvexClient.setAuthWithRefresh] to control the auth session.
class AuthHandleWrapper {
  final AuthHandle _handle;

  AuthHandleWrapper._(this._handle);

  /// Whether the user is currently authenticated.
  bool get isAuthenticated => _handle.isAuthenticated();

  /// Dispose the auth session, stopping token refresh and clearing auth.
  ///
  /// Call this when signing out or when you no longer need automatic token refresh.
  void dispose() => _handle.dispose();
}
