import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;
import 'package:convex_flutter/src/impl/convex_client_interface.dart';
import 'package:convex_flutter/src/rust/lib.dart' show WebSocketConnectionState, SubscriptionHandle, AuthHandle;
import 'package:convex_flutter/src/connection_status.dart';
import 'package:convex_flutter/src/convex_config.dart';
import 'package:convex_flutter/src/app_lifecycle_event.dart';
import 'package:convex_flutter/src/app_lifecycle_observer.dart';

/// Web (pure Dart) implementation of Convex client.
///
/// This implementation uses the browser's native WebSocket API for web platform,
/// avoiding the need for Rust toolchain or FFI. It implements the same
/// [IConvexClient] interface as [NativeConvexClient], ensuring API compatibility
/// across all platforms.
///
/// For mobile/desktop platforms, use [NativeConvexClient] instead.
class WebConvexClient implements IConvexClient {
  /// Configuration for this client
  @override
  final ConvexConfig config;

  /// WebSocket connection to Convex backend
  web.WebSocket? _ws;

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

  /// Current auth token
  String? _currentAuthToken;

  /// Lifecycle observer for app state changes
  late final AppLifecycleObserver _lifecycleObserver;

  /// Message ID counter for generating unique request IDs
  int _messageIdCounter = 0;

  /// Session ID for Convex sync protocol
  String? _sessionId;

  /// Query ID counter for subscriptions
  int _queryIdCounter = 0;

  /// Query set version counter for ModifyQuerySet messages
  int _querySetVersion = 0;

  /// Pending requests waiting for responses (query, mutation, action)
  final Map<int, Completer<String>> _pendingRequests = {};

  /// Active subscriptions
  final Map<String, _WebSubscription> _subscriptions = {};

  /// Reconnection attempt counter
  int _reconnectAttempts = 0;

  /// Maximum reconnection attempts
  static const int _maxReconnectAttempts = 10;

  /// Base reconnection delay
  static const Duration _baseReconnectDelay = Duration(seconds: 1);

  /// Timer for reconnection
  Timer? _reconnectTimer;

  /// Whether client is disposed
  bool _isDisposed = false;

  /// Private constructor
  WebConvexClient._(this.config);

  /// Factory method to create and initialize a web client.
  ///
  /// This handles:
  /// - WebSocket connection setup
  /// - Event listener registration
  /// - Lifecycle observer setup
  static Future<WebConvexClient> create(ConvexConfig config) async {
    debugPrint('=== [WebConvexClient] Creating web client ===');

    final client = WebConvexClient._(config);

    // Setup lifecycle observer
    // Note: On web, we don't reconnect on lifecycle events because:
    // 1. Page navigation triggers lifecycle events but doesn't disconnect WebSocket
    // 2. WebSocket onclose handler already manages reconnection
    // 3. Browser tab visibility changes are the only real "background" events
    client._lifecycleObserver = AppLifecycleObserver(
      onLifecycleChange: (event) {
        client._lifecycleController.add(event);
        // Do NOT trigger reconnection on web - let WebSocket manage itself
        debugPrint('=== [WebConvexClient] Lifecycle event: ${event.name} (no action on web) ===');
      },
    );

    // Establish WebSocket connection
    await client._connect();

    debugPrint('=== [WebConvexClient] Client created successfully ===');
    return client;
  }

  /// Establishes WebSocket connection to Convex backend.
  Future<void> _connect() async {
    if (_isDisposed) return;

    debugPrint('=== [WebConvexClient] Connecting to Convex ===');

    try {
      // Convert HTTPS to WSS URL with correct Convex sync endpoint
      // Format: wss://deployment.convex.cloud/api/{version}/sync
      final wsUrl = config.deploymentUrl.replaceFirst('https', 'wss');
      final fullUrl = '$wsUrl/api/sync';

      debugPrint('=== [WebConvexClient] WebSocket URL: $fullUrl ===');

      // Update state to connecting
      _updateConnectionState(WebSocketConnectionState.connecting);

      // Create WebSocket connection
      _ws = web.WebSocket(fullUrl);

      // Setup event listeners
      _setupWebSocketListeners();

      debugPrint('=== [WebConvexClient] WebSocket connection initiated ===');
    } catch (e) {
      debugPrint('ERROR: [WebConvexClient] Connection failed: $e');
      _scheduleReconnect();
    }
  }

  /// Sets up WebSocket event listeners.
  void _setupWebSocketListeners() {
    final ws = _ws;
    if (ws == null) return;

    // Connection opened
    ws.onopen = (web.Event event) {
      debugPrint('=== [WebConvexClient] WebSocket opened ===');
      _reconnectAttempts = 0; // Reset reconnection counter
      _querySetVersion = 0; // Reset query set version for new connection
      _updateConnectionState(WebSocketConnectionState.connected);

      // Send Connect handshake (required by Convex protocol)
      _sendConnectMessage();

      // Send auth token if available
      if (_currentAuthToken != null) {
        _sendAuthMessage(_currentAuthToken!);
      }
    }.toJS;

    // Connection closed
    ws.onclose = (web.CloseEvent event) {
      final code = event.code;
      final reason = event.reason;
      final wasClean = event.wasClean;
      debugPrint('=== [WebConvexClient] WebSocket closed ===');
      debugPrint('=== [WebConvexClient] Close code: $code, reason: "$reason", wasClean: $wasClean ===');
      _updateConnectionState(WebSocketConnectionState.connecting);

      // Attempt reconnection if not disposed
      if (!_isDisposed) {
        _scheduleReconnect();
      }
    }.toJS;

    // Connection error
    ws.onerror = (web.Event event) {
      debugPrint('ERROR: [WebConvexClient] WebSocket error occurred');
      debugPrint('ERROR: [WebConvexClient] Event type: ${event.type}');
      _updateConnectionState(WebSocketConnectionState.connecting);
    }.toJS;

    // Message received
    ws.onmessage = (web.MessageEvent event) {
      final data = event.data;

      // Convert JSAny? to String
      final dataString = (data as JSString?)?.toDart;
      if (dataString != null) {
        _handleMessage(dataString);
      } else {
        debugPrint('WARNING: [WebConvexClient] Received non-string message');
      }
    }.toJS;
  }

  /// Handles incoming WebSocket messages.
  void _handleMessage(String data) {
    try {
      debugPrint('=== [WebConvexClient] RAW MESSAGE: $data ===');

      final message = jsonDecode(data) as Map<String, dynamic>;
      final type = message['type'] as String?;
      final id = message['id'] as String?;

      debugPrint('=== [WebConvexClient] Received message type: $type, id: $id ===');

      switch (type) {
        case 'Transition':
          // Query subscription updates
          _handleTransition(message);
          break;

        case 'MutationResponse':
          _handleMutationResponse(message);
          break;

        case 'ActionResponse':
          _handleActionResponse(message);
          break;

        case 'Ping':
          // Respond to server ping
          _sendPong();
          break;

        case 'FatalError':
          _handleFatalError(message);
          break;

        case 'AuthError':
          _handleAuthError(message);
          break;

        default:
          debugPrint('WARNING: [WebConvexClient] Unknown message type: $type');
      }
    } catch (e) {
      debugPrint('ERROR: [WebConvexClient] Failed to parse message: $e');
    }
  }

  /// Handles Transition messages (query subscription updates).
  void _handleTransition(Map<String, dynamic> message) {
    final modifications = message['modifications'] as List?;
    if (modifications == null) return;

    for (final mod in modifications) {
      final queryId = mod['queryId']?.toString();
      if (queryId == null) continue;

      final subscription = _subscriptions[queryId];
      if (subscription == null) continue;

      final value = mod['value'];
      if (value != null) {
        final valueJson = jsonEncode(value);
        subscription.onUpdate(valueJson);
      }
    }
  }

  /// Handles MutationResponse messages.
  void _handleMutationResponse(Map<String, dynamic> message) {
    final requestId = message['requestId'] as int?;
    if (requestId == null) return;

    final completer = _pendingRequests.remove(requestId);
    if (completer == null) return;

    final result = message['result'];
    if (result != null) {
      final resultJson = jsonEncode(result);
      completer.complete(resultJson);
    } else {
      completer.completeError(Exception('No result in mutation response'));
    }
  }

  /// Handles ActionResponse messages.
  void _handleActionResponse(Map<String, dynamic> message) {
    final requestId = message['requestId'] as int?;
    if (requestId == null) return;

    final completer = _pendingRequests.remove(requestId);
    if (completer == null) return;

    final result = message['result'];
    if (result != null) {
      final resultJson = jsonEncode(result);
      completer.complete(resultJson);
    } else {
      completer.completeError(Exception('No result in action response'));
    }
  }

  /// Handles FatalError messages.
  void _handleFatalError(Map<String, dynamic> message) {
    final error = message['error'] as String? ?? 'Unknown fatal error';
    debugPrint('FATAL ERROR: [WebConvexClient] $error');

    // Close connection on fatal error
    _ws?.close();
  }

  /// Handles AuthError messages.
  void _handleAuthError(Map<String, dynamic> message) {
    final error = message['error'] as String? ?? 'Authentication error';
    debugPrint('AUTH ERROR: [WebConvexClient] $error');

    // Clear auth and notify
    _authStateController.add(false);
  }

  /// Sends Pong response to server Ping.
  void _sendPong() {
    try {
      _sendMessage({
        'type': 'Event',
        'eventType': 'Pong',  // Required field
        'event': null,  // Required field (can be null)
      });
      debugPrint('=== [WebConvexClient] Sent Pong ===');
    } catch (e) {
      debugPrint('ERROR: [WebConvexClient] Failed to send Pong: $e');
    }
  }

  /// Sends Connect handshake message.
  void _sendConnectMessage() {
    try {
      // Generate or reuse session ID (must be valid UUID format)
      _sessionId ??= _generateUuid();

      _sendMessage({
        'type': 'Connect',
        'sessionId': _sessionId,
        'maxObservedTimestamp': null,
        'connectionCount': _reconnectAttempts + 1,
        'lastCloseReason': null,  // Required field
        'clientTs': DateTime.now().millisecondsSinceEpoch,  // Required field
      });
      debugPrint('=== [WebConvexClient] Sent Connect handshake ===');
    } catch (e) {
      debugPrint('ERROR: [WebConvexClient] Failed to send Connect: $e');
    }
  }

  /// Generates a RFC 4122 compliant UUID v4 string.
  String _generateUuid() {
    // UUID v4 format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
    // Where 4 = version 4, y = variant bits (8, 9, A, or B)
    final random = math.Random();

    // Generate random values for each segment
    final segment1 = random.nextInt(0x100000000); // 32 bits = 8 hex chars
    final segment2 = random.nextInt(0x10000);      // 16 bits = 4 hex chars
    final segment3 = random.nextInt(0x10000);      // 16 bits = 4 hex chars (we'll set version)
    final segment4 = random.nextInt(0x10000);      // 16 bits = 4 hex chars (we'll set variant)
    final segment5a = random.nextInt(0x100000000); // 32 bits = 8 hex chars
    final segment5b = random.nextInt(0x10000);     // 16 bits = 4 hex chars

    // Set version 4 (bits 12-15 of segment3 = 0100)
    final version4 = (segment3 & 0x0FFF) | 0x4000;

    // Set variant bits (bits 14-15 of segment4 = 10)
    final variant = (segment4 & 0x3FFF) | 0x8000;

    // Combine segment5 parts into 12 hex digits
    final segment5 = '${segment5a.toRadixString(16).padLeft(8, '0')}${segment5b.toRadixString(16).padLeft(4, '0')}';

    return '${segment1.toRadixString(16).padLeft(8, '0')}-'
           '${segment2.toRadixString(16).padLeft(4, '0')}-'
           '${version4.toRadixString(16).padLeft(4, '0')}-'
           '${variant.toRadixString(16).padLeft(4, '0')}-'
           '$segment5';
  }

  /// Updates connection state and emits to stream.
  void _updateConnectionState(WebSocketConnectionState newState) {
    if (_currentConnectionState != newState) {
      debugPrint('=== [WebConvexClient] State transition: ${_currentConnectionState.name} → ${newState.name} ===');
      _currentConnectionState = newState;
      _connectionStateController.add(newState);
    }
  }

  /// Schedules a reconnection attempt with exponential backoff.
  void _scheduleReconnect() {
    if (_isDisposed) return;

    _reconnectTimer?.cancel();

    if (_reconnectAttempts >= _maxReconnectAttempts) {
      debugPrint('ERROR: [WebConvexClient] Max reconnection attempts reached');
      return;
    }

    // Exponential backoff: 1s, 2s, 4s, 8s, 16s, 32s (max)
    final delay = _baseReconnectDelay * (1 << _reconnectAttempts.clamp(0, 5));
    _reconnectAttempts++;

    debugPrint('=== [WebConvexClient] Scheduling reconnect attempt $_reconnectAttempts in ${delay.inSeconds}s ===');

    _reconnectTimer = Timer(delay, () {
      debugPrint('=== [WebConvexClient] Executing reconnect attempt $_reconnectAttempts ===');
      _connect();
    });
  }

  /// Generates a unique message ID.
  int _generateMessageId() {
    return _messageIdCounter++;
  }

  /// Sends a message over WebSocket.
  void _sendMessage(Map<String, dynamic> message) {
    final ws = _ws;
    if (ws == null || ws.readyState != web.WebSocket.OPEN) {
      throw StateError('WebSocket not connected');
    }

    final messageJson = jsonEncode(message);
    debugPrint('=== [WebConvexClient] SENDING: $messageJson ===');
    ws.send(messageJson.toJS);

    debugPrint('=== [WebConvexClient] Sent message: ${message['type']} (id: ${message['id']}) ===');
  }

  /// Sends authentication message.
  void _sendAuthMessage(String token) {
    try {
      // Send Authenticate message (Convex protocol)
      _sendMessage({
        'type': 'Authenticate',
        'token': token,
      });
      debugPrint('=== [WebConvexClient] Auth token sent ===');
    } catch (e) {
      debugPrint('ERROR: [WebConvexClient] Failed to send auth: $e');
    }
  }

  // ============================================================================
  // IConvexClient Implementation - Core Operations
  // ============================================================================

  @override
  Future<String> query(String name, Map<String, dynamic> args) async {
    // Queries in Convex protocol use ModifyQuerySet (like subscriptions)
    // We subscribe, wait for first result, then unsubscribe
    final queryId = _queryIdCounter++;
    final queryIdStr = queryId.toString();
    final completer = Completer<String>();

    // Create temporary subscription for one-shot query
    final subscription = _WebSubscription(
      id: queryIdStr,
      onUpdate: (value) {
        if (!completer.isCompleted) {
          completer.complete(value);
          // Auto-unsubscribe after getting result
          _unsubscribe(queryIdStr);
        }
      },
      onError: (message, value) {
        if (!completer.isCompleted) {
          completer.completeError(Exception(message));
          _subscriptions.remove(queryIdStr);
        }
      },
    );
    _subscriptions[queryIdStr] = subscription;

    try {
      // Send ModifyQuerySet with Add (Convex protocol for queries)
      final baseVersion = _querySetVersion;
      final newVersion = ++_querySetVersion;

      _sendMessage({
        'type': 'ModifyQuerySet',
        'baseVersion': baseVersion,
        'newVersion': newVersion,
        'modifications': [
          {
            'type': 'Add',
            'queryId': queryId,
            'udfPath': name,
            'args': [args],  // Args must be array
          }
        ],
      });

      return await completer.future.timeout(
        config.operationTimeout,
        onTimeout: () {
          _subscriptions.remove(queryIdStr);
          throw TimeoutException('Query timeout: $name');
        },
      );
    } catch (e) {
      _subscriptions.remove(queryIdStr);
      rethrow;
    }
  }

  @override
  Future<String> mutation({
    required String name,
    required Map<String, dynamic> args,
  }) async {
    final requestId = _generateMessageId();
    final completer = Completer<String>();
    _pendingRequests[requestId] = completer;

    try {
      // Send Mutation message (Convex protocol)
      _sendMessage({
        'type': 'Mutation',
        'requestId': requestId,
        'udfPath': name,  // Use udfPath instead of name
        'args': [args],   // Args must be array, not object
      });

      return await completer.future.timeout(
        config.operationTimeout,
        onTimeout: () {
          _pendingRequests.remove(requestId);
          throw TimeoutException('Mutation timeout: $name');
        },
      );
    } catch (e) {
      _pendingRequests.remove(requestId);
      rethrow;
    }
  }

  @override
  Future<String> action({
    required String name,
    required Map<String, dynamic> args,
  }) async {
    final requestId = _generateMessageId();
    final completer = Completer<String>();
    _pendingRequests[requestId] = completer;

    try {
      // Send Action message (Convex protocol)
      _sendMessage({
        'type': 'Action',
        'requestId': requestId,
        'udfPath': name,  // Use udfPath instead of name
        'args': [args],   // Args must be array, not object
      });

      return await completer.future.timeout(
        config.operationTimeout,
        onTimeout: () {
          _pendingRequests.remove(requestId);
          throw TimeoutException('Action timeout: $name');
        },
      );
    } catch (e) {
      _pendingRequests.remove(requestId);
      rethrow;
    }
  }

  @override
  Future<SubscriptionHandle> subscribe({
    required String name,
    required Map<String, dynamic> args,
    required void Function(String) onUpdate,
    required void Function(String, String?) onError,
  }) async {
    // Use incrementing query ID (Convex protocol requirement)
    final queryId = _queryIdCounter++;
    final queryIdStr = queryId.toString();

    // Create subscription record
    final subscription = _WebSubscription(
      id: queryIdStr,
      onUpdate: onUpdate,
      onError: onError,
    );
    _subscriptions[queryIdStr] = subscription;

    try {
      // Send ModifyQuerySet with Add modification (Convex protocol)
      final baseVersion = _querySetVersion;
      final newVersion = ++_querySetVersion;

      _sendMessage({
        'type': 'ModifyQuerySet',
        'baseVersion': baseVersion,
        'newVersion': newVersion,
        'modifications': [
          {
            'type': 'Add',
            'queryId': queryId,
            'udfPath': name,  // Use udfPath instead of name
            'args': [args],   // Args must be array, not object
          }
        ],
      });

      debugPrint('=== [WebConvexClient] Subscription created: queryId=$queryId ===');

      // Return handle for cancellation
      return _WebSubscriptionHandle(
        onCancel: () {
          _unsubscribe(queryIdStr);
        },
      );
    } catch (e) {
      _subscriptions.remove(queryIdStr);
      rethrow;
    }
  }

  /// Unsubscribes from a subscription.
  void _unsubscribe(String queryIdStr) {
    final subscription = _subscriptions.remove(queryIdStr);
    if (subscription == null) return;

    debugPrint('=== [WebConvexClient] Unsubscribing: queryId=$queryIdStr ===');

    try {
      final queryId = int.tryParse(queryIdStr);
      if (queryId == null) return;

      // Send ModifyQuerySet with Remove modification (Convex protocol)
      final baseVersion = _querySetVersion;
      final newVersion = ++_querySetVersion;

      _sendMessage({
        'type': 'ModifyQuerySet',
        'baseVersion': baseVersion,
        'newVersion': newVersion,
        'modifications': [
          {
            'type': 'Remove',
            'queryId': queryId,
          }
        ],
      });
    } catch (e) {
      debugPrint('ERROR: [WebConvexClient] Failed to send unsubscribe: $e');
    }
  }

  // ============================================================================
  // IConvexClient Implementation - Authentication
  // ============================================================================

  @override
  Future<void> setAuth({required String? token}) async {
    _currentAuthToken = token;

    if (token != null) {
      _sendAuthMessage(token);
      _authStateController.add(true);
    } else {
      _sendAuthMessage(''); // Clear auth
      _authStateController.add(false);
    }
  }

  @override
  Future<AuthHandle> setAuthWithRefresh({
    required Future<String?> Function() tokenFetcher,
    void Function(bool isAuthenticated)? onAuthChange,
  }) async {
    // TODO: Implement token refresh for web
    // For now, just fetch token once and set it
    final token = await tokenFetcher();
    await setAuth(token: token);

    if (onAuthChange != null) {
      onAuthChange(token != null);
    }

    // Return a simple auth handle (no auto-refresh yet)
    return _WebAuthHandle(
      isAuth: token != null,
      onDispose: () async {
        await setAuth(token: null);
      },
    );
  }

  @override
  Future<void> clearAuth() async {
    await setAuth(token: null);
  }

  @override
  Stream<bool> get authState => _authStateController.stream;

  @override
  bool get isAuthenticated => _currentAuthToken != null;

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
      await query(config.healthCheckQuery!, {});
      return ConnectionStatus.connected;
    } on TimeoutException {
      return ConnectionStatus.timeout;
    } catch (e) {
      return ConnectionStatus.error;
    }
  }

  @override
  Future<bool> reconnect() async {
    debugPrint('=== [WebConvexClient] Manual reconnect requested ===');

    // Close existing connection if any
    _ws?.close();
    _ws = null;

    // Reset reconnection counter for manual reconnect
    _reconnectAttempts = 0;

    // Attempt connection
    try {
      await _connect();

      // Wait a bit for connection to establish
      await Future.delayed(const Duration(seconds: 2));

      return isConnected;
    } catch (e) {
      debugPrint('ERROR: [WebConvexClient] Manual reconnect failed: $e');
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
    if (_isDisposed) return;

    debugPrint('=== [WebConvexClient] Disposing client ===');
    _isDisposed = true;

    // Cancel reconnection timer
    _reconnectTimer?.cancel();

    // Close WebSocket
    _ws?.close();
    _ws = null;

    // Dispose lifecycle observer
    _lifecycleObserver.dispose();

    // Close streams
    _authStateController.close();
    _lifecycleController.close();
    _connectionStateController.close();

    // Clear pending requests and subscriptions
    _pendingRequests.clear();
    _subscriptions.clear();

    debugPrint('=== [WebConvexClient] Client disposed ===');
  }
}

/// Internal subscription record for web client.
class _WebSubscription {
  final String id;
  final void Function(String) onUpdate;
  final void Function(String, String?) onError;

  _WebSubscription({
    required this.id,
    required this.onUpdate,
    required this.onError,
  });
}

/// Web implementation of SubscriptionHandle.
class _WebSubscriptionHandle implements SubscriptionHandle {
  final void Function() onCancel;
  bool _isCancelled = false;

  _WebSubscriptionHandle({required this.onCancel});

  @override
  void cancel() {
    if (!_isCancelled) {
      _isCancelled = true;
      onCancel();
    }
  }

  @override
  void dispose() {
    cancel();
  }

  @override
  bool get isDisposed => _isCancelled;
}

/// Web implementation of AuthHandle.
class _WebAuthHandle implements AuthHandle {
  final bool isAuth;
  final Future<void> Function() onDispose;
  bool _isDisposed = false;

  _WebAuthHandle({
    required this.isAuth,
    required this.onDispose,
  });

  @override
  bool isAuthenticated() => isAuth && !_isDisposed;

  @override
  void dispose() {
    if (!_isDisposed) {
      _isDisposed = true;
      onDispose();
    }
  }

  @override
  bool get isDisposed => _isDisposed;
}
