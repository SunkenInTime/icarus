// Faults the gauntlet puts between the app and the server. They sit below
// the app's repository, where a real network fails: a ConvexTransport that
// loses, repeats or holds the answers to ops:applyBatch, and a TCP proxy the
// native client connects through, which the gauntlet can cut to take the app
// offline.
import 'dart:async';
import 'dart:io';

import 'package:icarus/collab/transport/convex_transport.dart';

/// What happens to the next ops:applyBatch the app sends.
enum BatchFault {
  /// Sent, and its answer is lost: the server applied it, the app hears
  /// nothing but a timeout.
  loseAnswer,

  /// Lost before it reaches the server.
  loseRequest,

  /// Delivered twice. The app gets the second answer.
  deliverTwice,

  /// Sent after a delay, while the user keeps editing.
  delay,

  /// Sent, and its answer is held until the process ends: the app is
  /// killed with the batch in flight.
  holdAnswerForever,

  /// Held before it is sent until [FaultyTransport.release].
  holdUntilReleased,
}

/// One ops:applyBatch the server answered, as the transport saw it, whether
/// or not the app got the answer.
final class SeenBatch {
  SeenBatch(this.args, this.result, {required this.delivered});

  final Map<String, Object?> args;
  final Map<String, Object?> result;
  final bool delivered;
}

/// The app's transport, with faults injected into ops:applyBatch.
final class FaultyTransport implements ConvexTransport {
  FaultyTransport(this._inner);

  final ConvexTransport _inner;
  final List<BatchFault> _pending = [];
  Completer<void>? _held;

  /// Every ops:applyBatch the server answered, in order.
  final List<SeenBatch> seen = [];

  /// Completes each time the app sends an ops:applyBatch.
  final StreamController<void> _sent = StreamController.broadcast();
  Stream<void> get batchSent => _sent.stream;

  /// Applies [fault] to the next ops:applyBatch the app sends.
  void inject(BatchFault fault) => _pending.add(fault);

  /// Whether no fault is waiting for a batch and none is holding one.
  bool get isClear => _pending.isEmpty && _held == null;

  /// Sends the batch [BatchFault.holdUntilReleased] is holding.
  void release() => _held?.complete();

  @override
  Future<ConvexValue> mutation(String name, ConvexObject args) async {
    if (name != 'ops:applyBatch') return _inner.mutation(name, args);
    _sent.add(null);
    final fault = _pending.isEmpty ? null : _pending.removeAt(0);
    switch (fault) {
      case null:
        return _send(args);
      case BatchFault.delay:
        await Future<void>.delayed(const Duration(milliseconds: 400));
        return _send(args);
      case BatchFault.loseRequest:
        throw TimeoutException('gauntlet: the request was lost');
      case BatchFault.loseAnswer:
        await _send(args, delivered: false);
        throw TimeoutException('gauntlet: the answer was lost');
      case BatchFault.deliverTwice:
        await _send(args, delivered: false);
        return _send(args);
      case BatchFault.holdAnswerForever:
        await _send(args, delivered: false);
        return Completer<ConvexValue>().future;
      case BatchFault.holdUntilReleased:
        final held = _held = Completer<void>();
        await held.future;
        _held = null;
        return _send(args);
    }
  }

  Future<ConvexValue> _send(ConvexObject args, {bool delivered = true}) async {
    final result = await _inner.mutation('ops:applyBatch', args);
    seen.add(SeenBatch(
      args.toDart(),
      (result.toDart() as Map).cast<String, Object?>(),
      delivered: delivered,
    ));
    return result;
  }

  @override
  Future<ConvexValue> query(String name, ConvexObject args) =>
      _inner.query(name, args);

  @override
  Future<ConvexValue> action(String name, ConvexObject args) =>
      _inner.action(name, args);

  @override
  Stream<ConvexValue> subscribe(String name, ConvexObject args) =>
      _inner.subscribe(name, args);

  @override
  Stream<List<ConvexValue>> subscribeTogether(
    List<(String name, ConvexObject args)> queries,
  ) =>
      _inner.subscribeTogether(queries);
}

/// A TCP proxy in front of the local deployment. The native client connects
/// through it; [goOffline] drops every connection and refuses new ones
/// until [goOnline], as a network that went away would.
final class SocketProxy {
  SocketProxy._(this._server, this._upstreamPort);

  final ServerSocket _server;
  final int _upstreamPort;
  final Set<Socket> _open = {};
  bool _offline = false;

  int get port => _server.port;
  bool get isOffline => _offline;

  static Future<SocketProxy> start(int upstreamPort) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = SocketProxy._(server, upstreamPort);
    server.listen(proxy._accept);
    return proxy;
  }

  Future<void> _accept(Socket client) async {
    if (_offline) {
      client.destroy();
      return;
    }
    final Socket upstream;
    try {
      upstream = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _upstreamPort,
      );
    } catch (_) {
      client.destroy();
      return;
    }
    if (_offline) {
      client.destroy();
      upstream.destroy();
      return;
    }
    _open
      ..add(client)
      ..add(upstream);
    void close() {
      _open
        ..remove(client)
        ..remove(upstream);
      client.destroy();
      upstream.destroy();
    }

    // A socket cut by goOffline fails its pending writes; that is the point.
    client.done.ignore();
    upstream.done.ignore();
    void forward(Socket to, List<int> data) {
      try {
        to.add(data);
      } catch (_) {
        close();
      }
    }

    client.listen(
      (data) => forward(upstream, data),
      onDone: close,
      onError: (_) => close(),
    );
    upstream.listen(
      (data) => forward(client, data),
      onDone: close,
      onError: (_) => close(),
    );
  }

  void goOffline() {
    _offline = true;
    for (final socket in _open.toList()) {
      socket.destroy();
    }
    _open.clear();
  }

  void goOnline() => _offline = false;

  Future<void> close() async {
    goOffline();
    await _server.close();
  }
}
