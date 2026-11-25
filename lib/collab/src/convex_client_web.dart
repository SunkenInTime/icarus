import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:icarus/collab/src/convex_client_types.dart';
import 'package:icarus/collab/transport/convex_transport.dart' show ResultStamp;

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

  /// The underlying sync client. The browser `ConvexClient` has `setAuth` but
  /// no `clearAuth`; clearing auth is only offered here.
  external _JsBaseConvexClient get client;
  external _JsConnectionState connectionState();
  external JSFunction subscribeToConnectionState(JSFunction callback);
  external void close();
}

@JS()
extension type _JsBaseConvexClient._(JSObject _) implements JSObject {
  external void clearAuth();
  external JSFunction addOnTransitionHandler(JSFunction handler);
}

@JS()
extension type _JsConnectionState._(JSObject _) implements JSObject {
  external bool get isWebSocketConnected;
  external int get connectionCount;
}

@JS()
extension type _JsTransition._(JSObject _) implements JSObject {
  external _JsLong get timestamp;
}

@JS()
extension type _JsLong._(JSObject _) implements JSObject {
  external int get high;
  external int get low;
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

class ConvexClient implements StampedValueSource {
  ConvexClient._(this._client, this.config) : _number = ++_built {
    if (config.countsTransitions) _countTransitions();
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

  static int _built = 0;
  final int _number;
  late ResultStamp _applied;
  final List<_Pending> _inThisDispatch = [];
  JSFunction? _transitionHandler;
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

  @override
  Future<SubscriptionHandle> subscribeValues({
    required List<({String name, Map<String, Object?> args})> queries,
    required void Function(List<Object?> values) onUpdate,
    required void Function(ConvexClientFunctionError error) onError,
  }) async {
    // Convex's client calls every listener whose query a server answer
    // changed in one synchronous pass, so values handed on a microtask later
    // all come from that one answer.
    final values = List<Object?>.filled(queries.length, null);
    final answered = List<bool>.filled(queries.length, false);
    var handOnScheduled = false;
    var cancelled = false;

    void handOnSoon() {
      if (handOnScheduled) return;
      handOnScheduled = true;
      scheduleMicrotask(() {
        handOnScheduled = false;
        if (cancelled || answered.contains(false)) return;
        onUpdate(List.unmodifiable(values));
      });
    }

    final handles = [
      for (final (index, query) in queries.indexed)
        _subscribeMember(
          query,
          onUpdate: (value) {
            values[index] = value;
            answered[index] = true;
            handOnSoon();
          },
          onError: (error) {
            // A failed query has no value until it answers again, so its
            // last one never goes out with the others' newer ones.
            answered[index] = false;
            onError(error);
          },
        ),
    ];
    return _WebGroupSubscriptionHandle(handles, onCancel: () {
      cancelled = true;
    });
  }

  _WebSubscriptionHandle _subscribeMember(
    ({String name, Map<String, Object?> args}) query, {
    required void Function(Object? value) onUpdate,
    required void Function(ConvexClientFunctionError error) onError,
  }) {
    final updateCallback = ((JSAny? value, JSAny? _) {
      onUpdate(_fromJsConvex(value));
    }).toJS;
    final errorCallback = ((JSAny? error, JSAny? _) {
      onError(_jsFunctionError(error));
    }).toJS;
    final unsubscribe = _client.onUpdate(
      query.name,
      _toJsConvex(query.args),
      updateCallback,
      errorCallback,
    );
    return _WebSubscriptionHandle(
      unsubscribe: unsubscribe,
      updateCallback: updateCallback,
      errorCallback: errorCallback,
    );
  }

  void _countTransitions() {
    _applied = ResultStamp(
      client: _number,
      connection: _client.connectionState().connectionCount,
      snapshot: 0,
    );
    _transitionHandler = ((JSAny? transition) {
      final time = _JsTransition._(transition as JSObject).timestamp;
      final nanos = time.high * 0x100000000 + time.low.toUnsigned(32);
      _applied = ResultStamp(
        client: _number,
        connection: _client.connectionState().connectionCount,
        snapshot: _applied.snapshot + 1,
        serverTime: nanos == 0 ? null : nanos,
      );
      for (final pending in _inThisDispatch) {
        pending.stamp = _applied;
      }
      _inThisDispatch.clear();
    }).toJS;
    _client.client.addOnTransitionHandler(_transitionHandler!);
  }

  void _mustCount() {
    if (_transitionHandler == null) {
      throw StateError(
        'Stamped calls need a client built with countsTransitions.',
      );
    }
  }

  void _handOnStamped(
    _Listener listener,
    void Function(ResultStamp stamp) deliver,
  ) {
    final pending = _Pending();
    _inThisDispatch.add(pending);
    scheduleMicrotask(() {
      _inThisDispatch.remove(pending);
      final claimed = pending.stamp;
      final first = !listener.answered;
      listener.answered = true;
      if (claimed == null && !first) {
        listener.broken(
          StateError(
            'An answer arrived outside a transition after the first one, so '
            'its state is unknown.',
          ),
          StackTrace.current,
        );
        return;
      }
      deliver(claimed ?? _applied);
    });
  }

  bool _isServerFailure(String name, Object? error) {
    try {
      return _jsErrorMessage(error as JSAny?).startsWith('[CONVEX M($name)] ');
    } catch (_) {
      return false;
    }
  }

  @override
  Future<StampedOutcome<Object?>> queryStamped(
    String name,
    Map<String, Object?> args,
  ) {
    _mustCount();
    final answered = Completer<StampedOutcome<Object?>>();
    var state = _OneShot.waiting;
    SubscriptionHandle? handle;
    Timer? deadline;
    void finish(_OneShot next, void Function() complete) {
      if (state != _OneShot.waiting) return;
      state = next;
      deadline?.cancel();
      handle?.cancel();
      complete();
    }

    deadline = Timer(
      config.operationTimeout,
      () => finish(
        _OneShot.timedOut,
        () => answered.completeError(
          TimeoutException('Query $name timed out', config.operationTimeout),
        ),
      ),
    );
    subscribeStamped(
      name: name,
      args: args,
      onResult: (outcome) =>
          finish(_OneShot.answered, () => answered.complete(outcome)),
      onBroken: (error, stackTrace) => finish(
        _OneShot.failed,
        () => answered.completeError(error, stackTrace),
      ),
    ).then(
      (next) {
        handle = next;
        if (state != _OneShot.waiting) next.cancel();
      },
      onError: (Object error, StackTrace stackTrace) => finish(
        _OneShot.failed,
        () => answered.completeError(error, stackTrace),
      ),
    );
    return answered.future;
  }

  @override
  Future<StampedOutcome<Object?>> mutationStamped({
    required String name,
    required Map<String, Object?> args,
  }) async {
    _mustCount();
    final promise = _client.mutation(name, _toJsConvex(args));
    final JSAny? result;
    try {
      result = await promise.toDart.timeout(config.operationTimeout);
    } on TimeoutException {
      throw TimeoutException('Mutation $name timed out', config.operationTimeout);
    } catch (error) {
      if (!_isServerFailure(name, error)) rethrow;
      return StampedFunctionError(_jsFunctionError(error), _applied);
    }
    return StampedAnswer(_fromJsConvex(result), _applied);
  }

  @override
  Future<SubscriptionHandle> subscribeStamped({
    required String name,
    required Map<String, Object?> args,
    required void Function(StampedOutcome<Object?> outcome) onResult,
    required void Function(Object error, StackTrace stackTrace) onBroken,
  }) async {
    _mustCount();
    final listener = _Listener(onBroken);
    final member = _subscribeRawMember(
      (name: name, args: args),
      listener,
      onUpdate: (value) => _handOnStamped(listener, (stamp) {
        if (!listener.active) return;
        final Object? converted;
        try {
          converted = _fromJsConvex(value);
        } catch (error, stackTrace) {
          listener.broken(error, stackTrace);
          return;
        }
        onResult(StampedAnswer(converted, stamp));
      }),
      onError: (error) => _handOnStamped(listener, (stamp) {
        if (!listener.active) return;
        final ConvexClientFunctionError converted;
        try {
          converted = _jsFunctionError(error);
        } catch (error, stackTrace) {
          listener.broken(error, stackTrace);
          return;
        }
        onResult(StampedFunctionError(converted, stamp));
      }),
    );
    return _WebGroupSubscriptionHandle([member], onCancel: () {
      listener.active = false;
    });
  }

  @override
  Future<SubscriptionHandle> subscribeValuesStamped({
    required List<({String name, Map<String, Object?> args})> queries,
    required void Function(StampedOutcome<List<Object?>> outcome) onResult,
    required void Function(Object error, StackTrace stackTrace) onBroken,
  }) async {
    _mustCount();
    if (queries.isEmpty) {
      throw ArgumentError.value(queries, 'queries', 'needs at least one query');
    }
    final values = List<Object?>.filled(queries.length, null);
    final answeredOn = List<ResultStamp?>.filled(queries.length, null);
    final group = _Listener(onBroken);
    ResultStamp? latest;
    var handOnScheduled = false;

    void handOnSoon() {
      if (handOnScheduled) return;
      handOnScheduled = true;
      scheduleMicrotask(() {
        handOnScheduled = false;
        final stamp = latest;
        if (!group.active || stamp == null) return;
        final complete = answeredOn.every(
          (answered) =>
              answered != null &&
              answered.client == stamp.client &&
              answered.connection == stamp.connection,
        );
        if (complete) onResult(StampedAnswer(List.unmodifiable(values), stamp));
      });
    }

    final handles = <_WebSubscriptionHandle>[];
    try {
      for (final (index, query) in queries.indexed) {
        final member = _Listener(group.broken);
        handles.add(
          _subscribeRawMember(
            query,
            member,
            onUpdate: (value) => _handOnStamped(member, (stamp) {
              if (!group.active) return;
              try {
                values[index] = _fromJsConvex(value);
              } catch (error, stackTrace) {
                group.broken(error, stackTrace);
                return;
              }
              answeredOn[index] = stamp;
              latest = stamp;
              handOnSoon();
            }),
            onError: (error) => _handOnStamped(member, (stamp) {
              if (!group.active) return;
              final ConvexClientFunctionError converted;
              try {
                converted = _jsFunctionError(error);
              } catch (error, stackTrace) {
                group.broken(error, stackTrace);
                return;
              }
              answeredOn[index] = null;
              latest = stamp;
              onResult(StampedFunctionError(converted, stamp));
            }),
          ),
        );
      }
    } catch (_) {
      group.active = false;
      for (final handle in handles) {
        handle.cancel();
      }
      rethrow;
    }
    return _WebGroupSubscriptionHandle(handles, onCancel: () {
      group.active = false;
    });
  }

  @override
  Future<int> connectionGeneration() async {
    _mustCount();
    return _client.connectionState().connectionCount;
  }

  _WebSubscriptionHandle _subscribeRawMember(
    ({String name, Map<String, Object?> args}) query,
    _Listener listener, {
    required void Function(JSAny? value) onUpdate,
    required void Function(JSAny? error) onError,
  }) {
    final updateCallback = ((JSAny? value, JSAny? _) {
      try {
        onUpdate(value);
      } catch (error, stackTrace) {
        listener.broken(error, stackTrace);
      }
    }).toJS;
    final errorCallback = ((JSAny? error, JSAny? _) {
      try {
        onError(error);
      } catch (failure, stackTrace) {
        listener.broken(failure, stackTrace);
      }
    }).toJS;
    final unsubscribe = _client.onUpdate(
      query.name,
      _toJsConvex(query.args),
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
        _client.client.clearAuth();
        _setAuthenticated(false);
      },
      tokenCallback: tokenCallback,
      authCallback: authCallback,
    );
  }

  int get authChanges => _authGeneration;

  Future<void> clearAuth() async {
    _authGeneration += 1;
    _client.client.clearAuth();
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

class _WebGroupSubscriptionHandle implements SubscriptionHandle {
  _WebGroupSubscriptionHandle(this._members, {required this.onCancel});

  final List<_WebSubscriptionHandle> _members;
  final void Function() onCancel;

  @override
  void cancel() {
    onCancel();
    for (final member in _members) {
      member.cancel();
    }
    _members.clear();
  }
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

final class _Pending {
  ResultStamp? stamp;
}

final class _Listener {
  _Listener(this._onBroken);

  final void Function(Object error, StackTrace stackTrace) _onBroken;
  bool active = true;
  bool answered = false;

  void broken(Object error, StackTrace stackTrace) {
    if (!active) return;
    active = false;
    _onBroken(error, stackTrace);
  }
}

enum _OneShot { waiting, answered, failed, timedOut }
