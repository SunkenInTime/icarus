import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:convex_flutter/src/impl/convex_client_interface.dart';
import 'package:convex_flutter/src/rust/lib.dart';
import 'package:convex_flutter/src/rust/frb_generated.dart';
import 'package:convex_flutter/src/utils.dart';
import 'package:convex_flutter/src/connection_status.dart';
import 'package:convex_flutter/src/convex_config.dart';
import 'package:convex_flutter/src/app_lifecycle_event.dart';
import 'package:convex_flutter/src/app_lifecycle_observer.dart';

/// Native (FFI-based) implementation of Convex client.
///
/// This implementation uses Flutter Rust Bridge to call into the official
/// Convex Rust SDK for mobile and desktop platforms (Android, iOS, macOS,
/// Windows, Linux).
///
/// For web platform, use [WebConvexClient] instead.
class NativeConvexClient implements IConvexClient {
  /// The underlying Rust FFI client
  final MobileConvexClient _rustClient;

  /// Configuration for this client
  @override
  final ConvexConfig config;

  /// Stream controller for auth state changes
  final StreamController<bool> _authStateController =
      StreamController<bool>.broadcast();

  /// Stream controller for lifecycle events
  final StreamController<AppLifecycleEvent> _lifecycleController =
      StreamController<AppLifecycleEvent>.broadcast();

  /// Stream controller for WebSocket connection state changes
  final StreamController<WebSocketConnectionState> _connectionStateController =
      StreamController<WebSocketConnectionState>.broadcast();

  /// Current connection state (cached for sync access)
  WebSocketConnectionState _currentConnectionState =
      WebSocketConnectionState.connecting;

  /// Current auth handle (if using refresh-based auth)
  AuthHandle? _currentAuthHandle;

  /// Lifecycle observer for app state changes
  late final AppLifecycleObserver _lifecycleObserver;

  /// Private constructor
  NativeConvexClient._(this._rustClient, this.config);

  /// Factory method to create and initialize a native client.
  ///
  /// This handles:
  /// - Rust FFI library initialization
  /// - WebSocket state listener setup
  /// - Lifecycle observer setup
  static Future<NativeConvexClient> create(ConvexConfig config) async {
    // Initialize Rust FFI library
    await RustLib.init();

    // Create Rust client instance
    final rustClient = MobileConvexClient(
      deploymentUrl: config.deploymentUrl,
      clientId: config.clientId ?? 'flutter-client',
    );

    // Create native client wrapper
    final client = NativeConvexClient._(rustClient, config);

    // Setup connection state listener BEFORE any operations
    // This prevents race conditions where state changes are missed
    await client._setupConnectionStateListener();

    // Setup lifecycle observer
    client._lifecycleObserver = AppLifecycleObserver(
      onLifecycleChange: (event) {
        client._lifecycleController.add(event);
      },
    );

    return client;
  }

  /// Sets up the WebSocket connection state listener.
  ///
  /// This must be called before any queries/mutations to capture all state changes.
  Future<void> _setupConnectionStateListener() async {
    debugPrint('=== [NativeConvexClient] Setting up WebSocket state listener ===');
    debugPrint('=== [NativeConvexClient] Current state: ${_currentConnectionState.name} ===');

    try {
      await _rustClient.onWebsocketStateChange(
        onStateChange: (state) async {
          debugPrint('=== [NativeConvexClient] State changed: ${state.name} ===');
          _currentConnectionState = state;
          _connectionStateController.add(state);
          debugPrint('=== [NativeConvexClient] Stream emission complete ===');
        },
      );
      debugPrint('=== [NativeConvexClient] Listener registered successfully ===');
    } catch (e) {
      debugPrint('ERROR: [NativeConvexClient] Listener setup failed: $e');
      rethrow;
    }
  }

  // ============================================================================
  // IConvexClient Implementation - Core Operations
  // ============================================================================

  @override
  Future<String> query(String name, Map<String, dynamic> args) async {
    final formattedArgs = buildArgs(args);
    return await _rustClient
        .query(name: name, args: formattedArgs)
        .timeout(config.operationTimeout);
  }

  @override
  Future<String> mutation({
    required String name,
    required Map<String, dynamic> args,
  }) async {
    final formattedArgs = buildArgs(args);
    return await _rustClient
        .mutation(name: name, args: formattedArgs)
        .timeout(config.operationTimeout);
  }

  @override
  Future<String> action({
    required String name,
    required Map<String, dynamic> args,
  }) async {
    final formattedArgs = buildArgs(args);
    return await _rustClient
        .action(name: name, args: formattedArgs)
        .timeout(config.operationTimeout);
  }

  @override
  Future<SubscriptionHandle> subscribe({
    required String name,
    required Map<String, dynamic> args,
    required void Function(String) onUpdate,
    required void Function(String, String?) onError,
  }) async {
    final formattedArgs = buildArgs(args);
    return await _rustClient.subscribe(
      name: name,
      args: formattedArgs,
      onUpdate: (value) => onUpdate(value),
      onError: (message, value) => onError(message, value),
    );
  }

  // ============================================================================
  // IConvexClient Implementation - Authentication
  // ============================================================================

  @override
  Future<void> setAuth({required String? token}) async {
    // Clear any existing refresh-based auth
    _currentAuthHandle?.dispose();
    _currentAuthHandle = null;

    await _rustClient.setAuth(token: token);
    _authStateController.add(token != null);
  }

  @override
  Future<AuthHandle> setAuthWithRefresh({
    required Future<String?> Function() tokenFetcher,
    void Function(bool isAuthenticated)? onAuthChange,
  }) async {
    // Dispose any existing auth handle
    _currentAuthHandle?.dispose();

    final handle = await _rustClient.setAuthWithRefresh(
      fetchToken: () async => await tokenFetcher(),
      onAuthChange: (bool isAuth) async {
        onAuthChange?.call(isAuth);
        _authStateController.add(isAuth);
      },
    );

    _currentAuthHandle = handle;
    return handle;
  }

  @override
  Future<void> clearAuth() async {
    _currentAuthHandle?.dispose();
    _currentAuthHandle = null;
    await _rustClient.setAuth(token: null);
    _authStateController.add(false);
  }

  @override
  Stream<bool> get authState => _authStateController.stream;

  @override
  bool get isAuthenticated => _currentAuthHandle?.isAuthenticated() ?? false;

  // ============================================================================
  // IConvexClient Implementation - Connection Management
  // ============================================================================

  @override
  Stream<WebSocketConnectionState> get connectionState =>
      _connectionStateController.stream;

  @override
  WebSocketConnectionState get currentConnectionState => _currentConnectionState;

  @override
  bool get isConnected =>
      _currentConnectionState == WebSocketConnectionState.connected;

  @override
  @Deprecated('Use connectionState stream for real-time monitoring')
  Future<ConnectionStatus> checkConnection() async {
    if (config.healthCheckQuery == null) {
      throw StateError(
        'No health check query configured. '
        'Set healthCheckQuery in ConvexConfig or use a real query.',
      );
    }

    try {
      await _rustClient
          .query(name: config.healthCheckQuery!, args: {})
          .timeout(config.operationTimeout);
      return ConnectionStatus.connected;
    } on TimeoutException {
      return ConnectionStatus.timeout;
    } catch (e) {
      return ConnectionStatus.error;
    }
  }

  @override
  Future<bool> reconnect() async {
    try {
      final status = await checkConnection();
      return status == ConnectionStatus.connected;
    } catch (e) {
      // If healthCheckQuery not configured, just return false
      return false;
    }
  }

  // ============================================================================
  // IConvexClient Implementation - Lifecycle Management
  // ============================================================================

  @override
  Stream<AppLifecycleEvent> get lifecycleEvents => _lifecycleController.stream;

  // ============================================================================
  // IConvexClient Implementation - Resource Management
  // ============================================================================

  @override
  void dispose() {
    _currentAuthHandle?.dispose();
    _lifecycleObserver.dispose();
    _authStateController.close();
    _lifecycleController.close();
    _connectionStateController.close();
  }
}
