import 'dart:async';
import 'dart:convert';

import 'package:convex_flutter/convex_flutter.dart' as convex_flutter;
import 'package:dartvex/dartvex.dart' as dartvex;

abstract interface class IcarusConvexTransport {
  String get name;

  int get bytesSent;

  int get bytesReceived;

  Future<void> authenticate(String? token);

  Future<Object?> mutation(String path, Map<String, Object?> arguments);

  Future<Object?> query(String path, Map<String, Object?> arguments);

  Future<LiveSubscription> subscribe(
    String path,
    Map<String, Object?> arguments,
  );

  Future<Duration> reconnect();

  Future<void> close();
}

final class LiveSubscription {
  LiveSubscription({
    required this.values,
    required Future<void> Function() cancel,
  }) : _cancel = cancel;

  final Stream<Object?> values;
  final Future<void> Function() _cancel;

  Future<void> cancel() => _cancel();
}

final class DartvexTransport implements IcarusConvexTransport {
  DartvexTransport(String deploymentUrl)
    : _client = dartvex.ConvexClient(deploymentUrl);

  final dartvex.ConvexClient _client;
  int _bytesSent = 0;
  int _bytesReceived = 0;

  @override
  String get name => 'dartvex';

  @override
  int get bytesSent => _bytesSent;

  @override
  int get bytesReceived => _bytesReceived;

  @override
  Future<void> authenticate(String? token) => _client.setAuth(token);

  @override
  Future<Object?> mutation(String path, Map<String, Object?> arguments) async {
    _recordSend(path, arguments);
    final result = await _client.mutate(path, arguments) as Object?;
    _recordReceive(result);
    return result;
  }

  @override
  Future<Object?> query(String path, Map<String, Object?> arguments) async {
    _recordSend(path, arguments);
    final result = await _client.query(path, arguments) as Object?;
    _recordReceive(result);
    return result;
  }

  @override
  Future<LiveSubscription> subscribe(
    String path,
    Map<String, Object?> arguments,
  ) async {
    final subscription = _client.subscribe(path, arguments);
    return LiveSubscription(
      values: subscription.stream
          .where((result) => result is dartvex.QuerySuccess)
          .cast<dartvex.QuerySuccess>()
          .map((result) {
            final value = result.value as Object?;
            _recordReceive(value);
            return value;
          }),
      cancel: () async {
        subscription.cancel();
        // Dartvex exposes a synchronous cancel that schedules its actual
        // unsubscribe. Give that task a turn before a process-level close.
        await Future<void>.delayed(const Duration(milliseconds: 25));
      },
    );
  }

  @override
  Future<Duration> reconnect() async {
    final stopwatch = Stopwatch()..start();
    await _client.reconnectNow('icarus-gauntlet');
    await _client.connectionState
        .firstWhere((state) => state == dartvex.ConnectionState.connected)
        .timeout(const Duration(seconds: 20));
    return stopwatch.elapsed;
  }

  @override
  Future<void> close() async => _client.close();

  void _recordSend(String path, Map<String, Object?> arguments) {
    _bytesSent += utf8
        .encode(jsonEncode({'path': path, 'args': arguments}))
        .length;
  }

  void _recordReceive(Object? value) {
    _bytesReceived += utf8.encode(jsonEncode(value)).length;
  }
}

final class ConvexFlutterTransport implements IcarusConvexTransport {
  ConvexFlutterTransport._(this._client);

  final convex_flutter.ConvexClient _client;
  convex_flutter.AuthHandleWrapper? _authHandle;
  int _bytesSent = 0;
  int _bytesReceived = 0;

  static Future<ConvexFlutterTransport> create(String deploymentUrl) async {
    await convex_flutter.ConvexClient.initialize(
      convex_flutter.ConvexConfig(
        deploymentUrl: deploymentUrl,
        clientId: 'icarus-runtime-gauntlet',
        operationTimeout: const Duration(seconds: 30),
        healthCheckQuery: 'users:me',
      ),
    );
    return ConvexFlutterTransport._(convex_flutter.ConvexClient.instance);
  }

  @override
  String get name => 'convex_flutter';

  @override
  int get bytesSent => _bytesSent;

  @override
  int get bytesReceived => _bytesReceived;

  @override
  Future<void> authenticate(String? token) async {
    _authHandle?.dispose();
    _authHandle = null;
    await _client.clearAuth();
    // The package's native refresh handle cancels asynchronously and clears
    // auth as it exits. Let that cancellation settle before installing the
    // replacement handle so it cannot erase the fresh token afterward.
    await Future<void>.delayed(const Duration(milliseconds: 25));
    if (token == null) return;
    _authHandle = await _client.setAuthWithRefresh(
      fetchToken: () async => token,
    );
  }

  @override
  Future<Object?> mutation(String path, Map<String, Object?> arguments) async {
    _recordSend(path, arguments);
    final raw = await _client.mutation(
      name: path,
      args: arguments.cast<String, dynamic>(),
    );
    _bytesReceived += utf8.encode(raw).length;
    return jsonDecode(raw) as Object?;
  }

  @override
  Future<Object?> query(String path, Map<String, Object?> arguments) async {
    _recordSend(path, arguments);
    final raw = await _client.query(path, arguments.cast<String, dynamic>());
    _bytesReceived += utf8.encode(raw).length;
    return jsonDecode(raw) as Object?;
  }

  @override
  Future<LiveSubscription> subscribe(
    String path,
    Map<String, Object?> arguments,
  ) async {
    final controller = StreamController<Object?>.broadcast();
    var active = true;
    final handle = await _client.subscribe(
      name: path,
      args: arguments.cast<String, dynamic>(),
      onUpdate: (value) {
        if (!active) return;
        _bytesReceived += utf8.encode(value).length;
        controller.add(jsonDecode(value) as Object?);
      },
      onError: (message, value) {
        if (!active) return;
        controller.addError(
          StateError(value == null ? message : '$message: $value'),
        );
      },
    );
    return LiveSubscription(
      values: controller.stream,
      cancel: () async {
        active = false;
        handle.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 25));
        await controller.close();
      },
    );
  }

  @override
  Future<Duration> reconnect() async {
    final stopwatch = Stopwatch()..start();
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final connected = await _client.reconnect().timeout(
          const Duration(seconds: 1),
        );
        if (connected) return stopwatch.elapsed;
      } catch (_) {
        // The public reconnect call is a health query rather than a socket
        // transition. Poll it within the shared bounded recovery window.
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw StateError('convex_flutter failed to reconnect within 20 seconds');
  }

  @override
  Future<void> close() async {
    _authHandle?.dispose();
    _authHandle = null;
    _client.dispose();
  }

  void _recordSend(String path, Map<String, Object?> arguments) {
    _bytesSent += utf8
        .encode(jsonEncode({'path': path, 'args': arguments}))
        .length;
  }
}
