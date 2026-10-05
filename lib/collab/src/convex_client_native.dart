import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:convex_flutter/convex_flutter.dart' as native;
import 'package:icarus/collab/src/convex_client_types.dart';

class ConvexClient implements ConvexClientValueSource {
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

  @override
  Future<Object?> queryValue(String name, Map<String, Object?> args) =>
      _readValue(() => _client.query(name, _convexDartToJson(args)));

  Future<String> mutation({
    required String name,
    required Map<String, dynamic> args,
  }) =>
      _client.mutation(name: name, args: args);

  @override
  Future<Object?> mutationValue({
    required String name,
    required Map<String, Object?> args,
  }) =>
      _readValue(
        () => _client.mutation(name: name, args: _convexDartToJson(args)),
      );

  Future<String> action({
    required String name,
    required Map<String, dynamic> args,
  }) =>
      _client.action(name: name, args: args);

  @override
  Future<Object?> actionValue({
    required String name,
    required Map<String, Object?> args,
  }) =>
      _readValue(
        () => _client.action(name: name, args: _convexDartToJson(args)),
      );

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

  @override
  Future<SubscriptionHandle> subscribeValue({
    required String name,
    required Map<String, Object?> args,
    required void Function(Object? value) onUpdate,
    required void Function(ConvexClientFunctionError error) onError,
  }) async {
    final handle = await _client.subscribe(
      name: name,
      args: _convexDartToJson(args),
      onUpdate: (value) => onUpdate(_convexJsonToDart(jsonDecode(value))),
      onError: (message, value) => onError(
        _nativeFunctionError(message: message, encodedData: value),
      ),
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

  Future<Object?> _readValue(Future<String> Function() operation) async {
    try {
      return _convexJsonToDart(jsonDecode(await operation()));
    } on native.ClientError_ConvexError catch (error) {
      throw _nativeFunctionError(
        message: 'Convex function failed',
        encodedData: error.data,
      );
    }
  }

  static WebSocketConnectionState _mapConnectionState(
    native.WebSocketConnectionState state,
  ) {
    return state == native.WebSocketConnectionState.connected
        ? WebSocketConnectionState.connected
        : WebSocketConnectionState.connecting;
  }
}

ConvexClientFunctionError _nativeFunctionError({
  required String message,
  required String? encodedData,
}) {
  Object? data;
  if (encodedData != null) {
    try {
      data = _convexJsonToDart(jsonDecode(encodedData));
    } catch (_) {
      data = encodedData;
    }
  }
  final dataMap = data is Map ? data : const <Object?, Object?>{};
  final rawCode = dataMap['code']?.toString() ?? 'CONVEX_ERROR';
  final structuredMessage = dataMap['message'];
  return ConvexClientFunctionError(
    rawCode: rawCode,
    message: structuredMessage is String && structuredMessage.isNotEmpty
        ? structuredMessage
        : message,
    data: data,
  );
}

Map<String, dynamic> _convexDartToJson(Map<String, Object?> value) =>
    Map<String, dynamic>.from(_convexValueToJson(value) as Map);

Object? _convexValueToJson(Object? value) {
  if (value is BigInt) {
    final minimum = BigInt.parse('-9223372036854775808');
    final maximum = BigInt.parse('9223372036854775807');
    if (value < minimum || value > maximum) {
      throw FormatException('Convex int64 is out of range: $value');
    }
    final bytes = Uint8List(8);
    ByteData.sublistView(bytes).setInt64(0, value.toInt(), Endian.little);
    return <String, Object?>{r'$integer': base64Encode(bytes)};
  }
  if (value is Uint8List) {
    return <String, Object?>{r'$bytes': base64Encode(value)};
  }
  if (value is double && (!value.isFinite || value.isNegative && value == 0)) {
    final bytes = Uint8List(8);
    ByteData.sublistView(bytes).setFloat64(0, value, Endian.little);
    return <String, Object?>{r'$float': base64Encode(bytes)};
  }
  if (value is List) return value.map(_convexValueToJson).toList();
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key.toString(): _convexValueToJson(entry.value),
    };
  }
  return value;
}

Object? _convexJsonToDart(Object? value) {
  if (value is List) return value.map(_convexJsonToDart).toList();
  if (value is! Map) return value;
  if (value.length == 1 && value[r'$integer'] is String) {
    final bytes = base64Decode(value[r'$integer'] as String);
    if (bytes.length != 8) throw const FormatException('Invalid Convex int64');
    return BigInt.from(ByteData.sublistView(bytes).getInt64(0, Endian.little));
  }
  if (value.length == 1 && value[r'$bytes'] is String) {
    return Uint8List.fromList(base64Decode(value[r'$bytes'] as String));
  }
  if (value.length == 1 && value[r'$float'] is String) {
    final bytes = base64Decode(value[r'$float'] as String);
    if (bytes.length != 8) {
      throw const FormatException('Invalid Convex float64');
    }
    return ByteData.sublistView(bytes).getFloat64(0, Endian.little);
  }
  return <String, Object?>{
    for (final entry in value.entries)
      entry.key.toString(): _convexJsonToDart(entry.value),
  };
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
