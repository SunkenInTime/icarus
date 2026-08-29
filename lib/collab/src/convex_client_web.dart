import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:icarus/collab/src/convex_client_types.dart';

@JS('convex.ConvexClient')
extension type _JsConvexClient._(JSObject _) implements JSObject {
  external factory _JsConvexClient(String address);

  external JSPromise<JSAny?> query(String name, JSAny? args);
  external JSPromise<JSAny?> mutation(String name, JSAny? args);
  external JSPromise<JSAny?> action(String name, JSAny? args);
  external JSFunction onUpdate(
    String name,
    JSAny? args,
    JSFunction onUpdate, [
    JSFunction? onError,
  ]);
  external void setAuth(JSFunction fetchToken, [JSFunction? onChange]);
  external void clearAuth();
  external _JsConnectionState connectionState();
  external JSFunction subscribeToConnectionState(JSFunction callback);
  external void close();
}

@JS()
extension type _JsConnectionState._(JSObject _) implements JSObject {
  external bool get isWebSocketConnected;
}

@JS('BigInt')
external JSBigInt _createJsBigInt(String value);

@JS('String')
external String _jsString(JSAny? value);

@JS('Object.keys')
external JSArray<JSString> _jsObjectKeys(JSObject value);

extension type _JsUint8ArrayView._(JSObject _) implements JSObject {
  external JSArrayBuffer get buffer;
}

@JS('Uint8Array')
extension type _JsReadableUint8Array._(JSObject _) implements JSObject {
  external _JsReadableUint8Array(JSArrayBuffer buffer);

  external int get length;

  external int operator [](int index);
}

class ConvexClient implements ConvexClientValueSource {
  ConvexClient._(this._client, this.config) {
    _setConnectionState(
      _client.connectionState().isWebSocketConnected
          ? WebSocketConnectionState.connected
          : WebSocketConnectionState.connecting,
    );
    _connectionStateCallback = ((JSAny? value) {
      final connection = _JsConnectionState._(value as JSObject);
      _setConnectionState(
        connection.isWebSocketConnected
            ? WebSocketConnectionState.connected
            : WebSocketConnectionState.connecting,
      );
    }).toJS;
    _connectionStateUnsubscribe =
        _client.subscribeToConnectionState(_connectionStateCallback!);
  }

  final _JsConvexClient _client;
  final ConvexConfig config;
  final StreamController<WebSocketConnectionState> _connectionStateController =
      StreamController<WebSocketConnectionState>.broadcast();
  final StreamController<bool> _authStateController =
      StreamController<bool>.broadcast();

  WebSocketConnectionState _connectionState =
      WebSocketConnectionState.connecting;
  bool _isAuthenticated = false;
  int _authGeneration = 0;
  JSFunction? _connectionStateCallback;
  JSFunction? _connectionStateUnsubscribe;
  bool _disposed = false;

  static ConvexClient? _instance;

  static ConvexClient get instance {
    final client = _instance;
    if (client == null) {
      throw StateError('ConvexClient has not been initialized.');
    }
    return client;
  }

  static Future<void> initialize(ConvexConfig config) async {
    _instance = ConvexClient._(_JsConvexClient(config.deploymentUrl), config);
  }

  Stream<WebSocketConnectionState> get connectionState =>
      _connectionStateController.stream;

  WebSocketConnectionState get currentConnectionState => _connectionState;

  bool get isConnected =>
      _connectionState == WebSocketConnectionState.connected;

  Stream<bool> get authState => _authStateController.stream;

  bool get isAuthenticated => _isAuthenticated;

  Future<String> query(String name, Map<String, dynamic> args) {
    return _awaitResult('Query $name', _client.query(name, args.jsify()));
  }

  @override
  Future<Object?> queryValue(String name, Map<String, Object?> args) {
    return _awaitValue('Query $name', _client.query(name, _toJsConvex(args)));
  }

  Future<String> mutation({
    required String name,
    required Map<String, dynamic> args,
  }) {
    return _awaitResult(
      'Mutation $name',
      _client.mutation(name, args.jsify()),
    );
  }

  @override
  Future<Object?> mutationValue({
    required String name,
    required Map<String, Object?> args,
  }) {
    return _awaitValue(
      'Mutation $name',
      _client.mutation(name, _toJsConvex(args)),
    );
  }

  Future<String> action({
    required String name,
    required Map<String, dynamic> args,
  }) {
    return _awaitResult('Action $name', _client.action(name, args.jsify()));
  }

  @override
  Future<Object?> actionValue({
    required String name,
    required Map<String, Object?> args,
  }) {
    return _awaitValue(
      'Action $name',
      _client.action(name, _toJsConvex(args)),
    );
  }

  Future<SubscriptionHandle> subscribe({
    required String name,
    required Map<String, dynamic> args,
    required void Function(String value) onUpdate,
    required void Function(String message, String? value) onError,
  }) async {
    final updateCallback = ((JSAny? value, JSAny? _) {
      onUpdate(jsonEncode(value?.dartify()));
    }).toJS;
    final errorCallback = ((JSAny? error, JSAny? _) {
      onError(_jsErrorMessage(error), null);
    }).toJS;
    final unsubscribe = _client.onUpdate(
      name,
      args.jsify(),
      updateCallback,
      errorCallback,
    );
    return _WebSubscriptionHandle(
      unsubscribe: unsubscribe,
      updateCallback: updateCallback,
      errorCallback: errorCallback,
    );
  }

  @override
  Future<SubscriptionHandle> subscribeValue({
    required String name,
    required Map<String, Object?> args,
    required void Function(Object? value) onUpdate,
    required void Function(ConvexClientFunctionError error) onError,
  }) async {
    final updateCallback = ((JSAny? value, JSAny? _) {
      onUpdate(_fromJsConvex(value));
    }).toJS;
    final errorCallback = ((JSAny? error, JSAny? _) {
      onError(_jsFunctionError(error));
    }).toJS;
    final unsubscribe = _client.onUpdate(
      name,
      _toJsConvex(args),
      updateCallback,
      errorCallback,
    );
    return _WebSubscriptionHandle(
      unsubscribe: unsubscribe,
      updateCallback: updateCallback,
      errorCallback: errorCallback,
    );
  }

  Future<AuthHandleWrapper> setAuthWithRefresh({
    required Future<String?> Function() fetchToken,
    void Function(bool isAuthenticated)? onAuthChange,
  }) async {
    final generation = ++_authGeneration;
    final tokenCallback = ((JSAny? _) {
      return fetchToken().then<JSAny?>((token) => token?.toJS).toJS;
    }).toJS;
    final authCallback = ((JSBoolean authenticated) {
      if (generation != _authGeneration) {
        return;
      }
      final value = authenticated.toDart;
      _setAuthenticated(value);
      onAuthChange?.call(value);
    }).toJS;
    _client.setAuth(tokenCallback, authCallback);
    return _WebAuthHandleWrapper(
      onDispose: () {
        if (generation != _authGeneration) {
          return;
        }
        _authGeneration += 1;
        _client.clearAuth();
        _setAuthenticated(false);
      },
      tokenCallback: tokenCallback,
      authCallback: authCallback,
    );
  }

  Future<void> clearAuth() async {
    _authGeneration += 1;
    _client.clearAuth();
    _setAuthenticated(false);
  }

  Future<bool> reconnect() async {
    if (isConnected) {
      return true;
    }
    try {
      await connectionState
          .firstWhere((state) => state == WebSocketConnectionState.connected)
          .timeout(const Duration(seconds: 5));
      return true;
    } on TimeoutException {
      return false;
    }
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _connectionStateUnsubscribe?.callAsFunction();
    _connectionStateUnsubscribe = null;
    _connectionStateCallback = null;
    _client.close();
    _connectionStateController.close();
    _authStateController.close();
  }

  Future<String> _awaitResult(
    String operation,
    JSPromise<JSAny?> promise,
  ) async {
    try {
      final result = await promise.toDart.timeout(config.operationTimeout);
      return jsonEncode(result?.dartify());
    } on TimeoutException {
      throw TimeoutException('$operation timed out', config.operationTimeout);
    }
  }

  Future<Object?> _awaitValue(
    String operation,
    JSPromise<JSAny?> promise,
  ) async {
    try {
      final result = await promise.toDart.timeout(config.operationTimeout);
      return _fromJsConvex(result);
    } on TimeoutException {
      throw TimeoutException('$operation timed out', config.operationTimeout);
    } catch (error) {
      throw _jsFunctionError(error);
    }
  }

  void _setConnectionState(WebSocketConnectionState next) {
    if (_connectionState == next) {
      return;
    }
    _connectionState = next;
    _connectionStateController.add(next);
  }

  void _setAuthenticated(bool next) {
    if (_isAuthenticated == next) {
      return;
    }
    _isAuthenticated = next;
    _authStateController.add(next);
  }

  String _jsErrorMessage(JSAny? error) {
    if (error == null) {
      return 'Unknown Convex error';
    }
    try {
      final object = error as JSObject;
      final message = object.getProperty<JSAny?>('message'.toJS)?.dartify();
      if (message is String && message.isNotEmpty) {
        return message;
      }
      final dartValue = error.dartify();
      return dartValue?.toString() ?? 'Unknown Convex error';
    } catch (_) {
      return 'Unknown Convex error';
    }
  }

  ConvexClientFunctionError _jsFunctionError(Object? error) {
    JSAny? jsError;
    try {
      jsError = error as JSAny?;
    } catch (_) {
      return ConvexClientFunctionError(
        rawCode: 'CONVEX_ERROR',
        message: error?.toString() ?? 'Unknown Convex error',
        data: null,
      );
    }

    Object? data;
    String? objectCode;
    String message = _jsErrorMessage(jsError);
    try {
      final object = jsError as JSObject;
      final rawData = object.getProperty<JSAny?>('data'.toJS);
      data = _fromJsConvex(rawData);
      final rawObjectCode = object.getProperty<JSAny?>('code'.toJS);
      objectCode = rawObjectCode == null ? null : _jsString(rawObjectCode);
    } catch (_) {}
    final dataMap = data is Map ? data : const <Object?, Object?>{};
    final rawCode = dataMap['code']?.toString() ?? objectCode ?? 'CONVEX_ERROR';
    final structuredMessage = dataMap['message'];
    if (structuredMessage is String && structuredMessage.isNotEmpty) {
      message = structuredMessage;
    }
    return ConvexClientFunctionError(
      rawCode: rawCode,
      message: message,
      data: data,
    );
  }
}

JSAny? _toJsConvex(Object? value) {
  if (value is BigInt) return _createJsBigInt(value.toString());
  if (value is Uint8List) {
    final array = Uint8List.fromList(value).toJS;
    return _JsUint8ArrayView._(array).buffer;
  }
  if (value is List) {
    return value.map(_toJsConvex).toList(growable: false).toJS;
  }
  if (value is Map) {
    final object = JSObject();
    for (final entry in value.entries) {
      object.setProperty(entry.key.toString().toJS, _toJsConvex(entry.value));
    }
    return object;
  }
  return value.jsify();
}

Object? _fromJsConvex(JSAny? value) {
  if (value == null) return null;
  if (value.isA<JSBigInt>()) return BigInt.parse(_jsString(value));
  if (value.isA<JSArrayBuffer>()) {
    final bytes = _JsReadableUint8Array(value as JSArrayBuffer);
    return Uint8List.fromList([
      for (var index = 0; index < bytes.length; index += 1) bytes[index],
    ]);
  }
  if (value.isA<JSArray<JSAny?>>()) {
    return (value as JSArray<JSAny?>)
        .toDart
        .map(_fromJsConvex)
        .toList(growable: false);
  }
  if (value.isA<JSObject>()) {
    final object = value as JSObject;
    return <String, Object?>{
      for (final key in _jsObjectKeys(object).toDart)
        key.toDart: _fromJsConvex(
          object.getProperty<JSAny?>(key),
        ),
    };
  }
  return value.dartify();
}

class _WebSubscriptionHandle implements SubscriptionHandle {
  _WebSubscriptionHandle({
    required JSFunction unsubscribe,
    required JSFunction updateCallback,
    required JSFunction errorCallback,
  })  : _unsubscribe = unsubscribe,
        _callbacks = [updateCallback, errorCallback];

  JSFunction? _unsubscribe;
  final List<JSFunction> _callbacks;

  @override
  void cancel() {
    _unsubscribe?.callAsFunction();
    _unsubscribe = null;
    _callbacks.clear();
  }
}

class _WebAuthHandleWrapper implements AuthHandleWrapper {
  _WebAuthHandleWrapper({
    required void Function() onDispose,
    required JSFunction tokenCallback,
    required JSFunction authCallback,
  })  : _onDispose = onDispose,
        _callbacks = [tokenCallback, authCallback];

  void Function()? _onDispose;
  final List<JSFunction> _callbacks;

  @override
  void dispose() {
    _onDispose?.call();
    _onDispose = null;
    _callbacks.clear();
  }
}
