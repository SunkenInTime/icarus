import 'dart:async';

import 'package:convex_flutter/convex_flutter.dart' as native;
import 'package:icarus/collab/src/convex_client_types.dart';

class ConvexClient {
  ConvexClient._(this._client, this.config);

  final native.ConvexClient _client;
  final ConvexConfig config;

  static ConvexClient? _instance;

  static ConvexClient get instance {
    final client = _instance;
    if (client == null) {
      throw StateError('ConvexClient has not been initialized.');
    }
    return client;
  }

  static Future<void> initialize(ConvexConfig config) async {
    await native.ConvexClient.initialize(
      native.ConvexConfig(
        deploymentUrl: config.deploymentUrl,
        clientId: config.clientId,
        operationTimeout: config.operationTimeout,
        healthCheckQuery: config.healthCheckQuery,
      ),
    );
    _instance = ConvexClient._(native.ConvexClient.instance, config);
  }

  Stream<WebSocketConnectionState> get connectionState =>
      _client.connectionState.map(_mapConnectionState);

  WebSocketConnectionState get currentConnectionState =>
      _mapConnectionState(_client.currentConnectionState);

  bool get isConnected => _client.isConnected;

  Stream<bool> get authState => _client.authState;

  bool get isAuthenticated => _client.isAuthenticated;

  Future<String> query(String name, Map<String, dynamic> args) =>
      _client.query(name, args);

  Future<String> mutation({
    required String name,
    required Map<String, dynamic> args,
  }) =>
      _client.mutation(name: name, args: args);

  Future<String> action({
    required String name,
    required Map<String, dynamic> args,
  }) =>
      _client.action(name: name, args: args);

  Future<SubscriptionHandle> subscribe({
    required String name,
    required Map<String, dynamic> args,
    required void Function(String value) onUpdate,
    required void Function(String message, String? value) onError,
  }) async {
    final handle = await _client.subscribe(
      name: name,
      args: args,
      onUpdate: onUpdate,
      onError: onError,
    );
    return _NativeSubscriptionHandle(handle);
  }

  Future<AuthHandleWrapper> setAuthWithRefresh({
    required Future<String?> Function() fetchToken,
    void Function(bool isAuthenticated)? onAuthChange,
  }) async {
    final handle = await _client.setAuthWithRefresh(
      fetchToken: fetchToken,
      onAuthChange: onAuthChange,
    );
    return _NativeAuthHandleWrapper(handle);
  }

  Future<void> clearAuth() => _client.clearAuth();

  Future<bool> reconnect() => _client.reconnect();

  void dispose() => _client.dispose();

  static WebSocketConnectionState _mapConnectionState(
    native.WebSocketConnectionState state,
  ) {
    return state == native.WebSocketConnectionState.connected
        ? WebSocketConnectionState.connected
        : WebSocketConnectionState.connecting;
  }
}

class _NativeSubscriptionHandle implements SubscriptionHandle {
  _NativeSubscriptionHandle(this._handle);

  final native.SubscriptionHandle _handle;

  @override
  void cancel() => _handle.cancel();
}

class _NativeAuthHandleWrapper implements AuthHandleWrapper {
  _NativeAuthHandleWrapper(this._handle);

  final native.AuthHandleWrapper _handle;

  @override
  void dispose() => _handle.dispose();
}
