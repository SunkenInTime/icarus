import 'dart:async';

import 'package:icarus/collab/transport/convex_transport.dart';

final class StampedOver implements StampedConvexTransport {
  StampedOver(this.inner);

  final ConvexTransport inner;
  final calls = <String>[];
  var _snapshot = 0;

  ResultStamp _next() => ResultStamp(
        client: 1,
        connection: 1,
        snapshot: ++_snapshot,
        serverTime: 1000 + _snapshot,
      );

  Stream<Stamped<T>> _stamped<T>(Stream<T> answers) => answers.transform(
        StreamTransformer.fromHandlers(
          handleData: (value, sink) => sink.add(StampedValue(value, _next())),
          handleError: (error, stackTrace, sink) => switch (error) {
            final ConvexTransportError refused =>
              sink.add(StampedError(refused, _next())),
            _ => sink.addError(error, stackTrace),
          },
        ),
      );

  @override
  Future<ConvexValue> query(String name, ConvexObject args) {
    calls.add('query $name');
    return inner.query(name, args);
  }

  @override
  Stream<ConvexValue> subscribe(String name, ConvexObject args) {
    calls.add('subscribe $name');
    return inner.subscribe(name, args);
  }

  @override
  Stream<List<ConvexValue>> subscribeTogether(
    List<(String, ConvexObject)> queries,
  ) {
    calls
        .add('subscribeTogether ${queries.map((query) => query.$1).join(',')}');
    return inner.subscribeTogether(queries);
  }

  @override
  Future<ConvexValue> mutation(String name, ConvexObject args) =>
      inner.mutation(name, args);

  @override
  Future<ConvexValue> action(String name, ConvexObject args) =>
      inner.action(name, args);

  @override
  Future<Stamped<ConvexValue>> queryStamped(
    String name,
    ConvexObject args,
  ) async {
    calls.add('queryStamped $name');
    try {
      return StampedValue(await inner.query(name, args), _next());
    } on ConvexTransportError catch (refused) {
      return StampedError(refused, _next());
    }
  }

  @override
  Future<Stamped<ConvexValue>> mutationStamped(
    String name,
    ConvexObject args,
  ) =>
      throw UnimplementedError('mutationStamped $name');

  @override
  Stream<Stamped<ConvexValue>> subscribeStamped(
    String name,
    ConvexObject args,
  ) {
    calls.add('subscribeStamped $name');
    return _stamped(inner.subscribe(name, args));
  }

  @override
  Stream<Stamped<List<ConvexValue>>> subscribeTogetherStamped(
    List<(String, ConvexObject)> queries,
  ) {
    calls.add(
      'subscribeTogetherStamped ${queries.map((query) => query.$1).join(',')}',
    );
    return _stamped(inner.subscribeTogether(queries));
  }

  @override
  Future<({int client, int connection})> generation() async =>
      (client: 1, connection: 1);
}
