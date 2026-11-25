import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/src/convex_client_types.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/collab/transport/convex_transport_adapter.dart';

const _first =
    ResultStamp(client: 1, connection: 0, snapshot: 7, serverTime: 70);
const _second =
    ResultStamp(client: 1, connection: 2, snapshot: 11, serverTime: 70);

const _denied = ConvexClientFunctionError(
  rawCode: 'FORBIDDEN',
  message: 'not yours',
  data: {'code': 'FORBIDDEN', 'message': 'not yours'},
);

final class _Handle implements SubscriptionHandle {
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;
}

final class _Scripted implements StampedValueSource {
  _Scripted(this.outcomes, {this.breaksAfter});

  final List<StampedOutcome<Object?>> outcomes;
  final int? breaksAfter;
  final handle = _Handle();
  final asked = <String>[];

  @override
  Future<StampedOutcome<Object?>> queryStamped(
    String name,
    Map<String, Object?> args,
  ) async {
    asked.add('query $name');
    return outcomes.removeAt(0);
  }

  @override
  Future<StampedOutcome<Object?>> mutationStamped({
    required String name,
    required Map<String, Object?> args,
  }) async {
    asked.add('mutation $name');
    return outcomes.removeAt(0);
  }

  @override
  Future<SubscriptionHandle> subscribeStamped({
    required String name,
    required Map<String, Object?> args,
    required void Function(StampedOutcome<Object?> outcome) onResult,
    required void Function(Object error, StackTrace stackTrace) onBroken,
  }) async {
    asked.add('subscribe $name');
    scheduleMicrotask(() {
      for (final (index, outcome) in outcomes.indexed) {
        if (handle.cancelled) return;
        if (index == breaksAfter) {
          onBroken(
              const FormatException('a malformed answer'), StackTrace.current);
          return;
        }
        onResult(outcome);
      }
    });
    return handle;
  }

  @override
  Future<SubscriptionHandle> subscribeValuesStamped({
    required List<({String name, Map<String, Object?> args})> queries,
    required void Function(StampedOutcome<List<Object?>> outcome) onResult,
    required void Function(Object error, StackTrace stackTrace) onBroken,
  }) async {
    asked.add('together ${[for (final query in queries) query.name]}');
    scheduleMicrotask(() {
      for (final outcome in outcomes) {
        if (handle.cancelled) return;
        onResult(switch (outcome) {
          StampedAnswer(:final value, :final stamp) =>
            StampedAnswer([value, value], stamp),
          StampedFunctionError(:final error, :final stamp) =>
            StampedFunctionError(error, stamp),
        });
      }
    });
    return handle;
  }

  @override
  Future<int> connectionGeneration() async => 3;

  @override
  Future<Object?> queryValue(String name, Map<String, Object?> args) =>
      throw UnimplementedError();

  @override
  Future<Object?> mutationValue({
    required String name,
    required Map<String, Object?> args,
  }) =>
      throw UnimplementedError();

  @override
  Future<Object?> actionValue({
    required String name,
    required Map<String, Object?> args,
  }) =>
      throw UnimplementedError();

  @override
  Future<SubscriptionHandle> subscribeValue({
    required String name,
    required Map<String, Object?> args,
    required void Function(Object? value) onUpdate,
    required void Function(ConvexClientFunctionError error) onError,
  }) =>
      throw UnimplementedError();

  @override
  Future<SubscriptionHandle> subscribeValues({
    required List<({String name, Map<String, Object?> args})> queries,
    required void Function(List<Object?> values) onUpdate,
    required void Function(ConvexClientFunctionError error) onError,
  }) =>
      throw UnimplementedError();
}

({StampedPlatformTransport transport, ConvexQuery<HealthPingResult> ping})
    _over(_Scripted source) {
  final transport = StampedPlatformTransport(source);
  return (transport: transport, ping: IcarusConvexApi(transport).health.ping());
}

void main() {
  test('a stamped read decodes its value and keeps the stamp it came with',
      () async {
    final source = _Scripted([const StampedAnswer('ok', _first)]);
    final (:transport, :ping) = _over(source);

    final answer = await ping.stampedOn(transport).fetch();

    expect(source.asked, ['query health:ping']);
    expect(
      answer,
      isA<StampedValue<HealthPingResult>>()
          .having((it) => it.value, 'value', HealthPingResult.ok)
          .having((it) => it.stamp, 'stamp', _first),
    );
  });

  test('a function error is a stamped answer, not a thrown one', () async {
    final source = _Scripted([const StampedFunctionError(_denied, _second)]);
    final (:transport, :ping) = _over(source);

    final answer = await ping.stampedOn(transport).fetch();

    expect(
      answer,
      isA<StampedError<HealthPingResult>>()
          .having((it) => it.error.rawCode, 'code', 'FORBIDDEN')
          .having((it) => it.stamp, 'stamp', _second),
    );
  });

  test('a stamped mutation is answered with its stamp', () async {
    final source = _Scripted([const StampedAnswer(null, _second)]);
    final transport = StampedPlatformTransport(source);

    final answer = await transport.mutationStamped(
        'ops:applyBatch', ConvexObject(const {}));

    expect(source.asked, ['mutation ops:applyBatch']);
    expect(
      answer,
      isA<StampedValue<ConvexValue>>()
          .having((it) => it.value, 'value', isA<ConvexNull>())
          .having((it) => it.stamp, 'stamp', _second),
    );
  });

  test('a watch passes on errors and values in order, each with its stamp',
      () async {
    final source = _Scripted([
      const StampedAnswer('ok', _first),
      const StampedFunctionError(_denied, _second),
      const StampedAnswer('ok', _second),
    ]);
    final (:transport, :ping) = _over(source);

    final seen = await ping.stampedOn(transport).watch().take(3).toList();

    expect([for (final each in seen) each.stamp], [_first, _second, _second]);
    expect(seen[0], isA<StampedValue<HealthPingResult>>());
    expect(seen[1], isA<StampedError<HealthPingResult>>());
    expect(seen[2], isA<StampedValue<HealthPingResult>>());
    expect(source.handle.cancelled, isTrue);
  });

  test('a value the decoder refuses ends the watch with that error', () async {
    final source = _Scripted([
      const StampedAnswer('ok', _first),
      const StampedAnswer('not a ping', _second),
      const StampedAnswer('ok', _second),
    ]);
    final (:transport, :ping) = _over(source);

    final seen = <Stamped<HealthPingResult>>[];
    Object? failure;
    final ended = Completer<void>();
    ping.stampedOn(transport).watch().listen(
          seen.add,
          onError: (Object error) => failure = error,
          onDone: ended.complete,
        );
    await ended.future;

    expect(seen, hasLength(1));
    expect(failure, isA<ConvexDecodingException>());
    expect(source.handle.cancelled, isTrue);
  });

  test('a call that breaks ends the watch with its error', () async {
    final source = _Scripted(
      [const StampedAnswer('ok', _first), const StampedAnswer('ok', _second)],
      breaksAfter: 1,
    );
    final (:transport, :ping) = _over(source);
    final seen = <Stamped<HealthPingResult>>[];
    Object? failure;
    final ended = Completer<void>();
    ping.stampedOn(transport).watch().listen(
          seen.add,
          onError: (Object error) => failure = error,
          onDone: ended.complete,
        );
    await ended.future;

    expect(seen, hasLength(1));
    expect(failure, isA<FormatException>());
    expect(source.handle.cancelled, isTrue);
  });

  test('queries watched together come with one stamp per update', () async {
    final source = _Scripted([const StampedAnswer('ok', _first)]);
    final (:transport, :ping) = _over(source);

    final update = await StampedConvexQuery.watchTogether(
      transport,
      [ping, ping],
    ).first;

    expect(source.asked, ['together [health:ping, health:ping]']);
    expect(
      update,
      isA<StampedValue<List<Object?>>>().having((it) => it.value, 'values', [
        HealthPingResult.ok,
        HealthPingResult.ok
      ]).having((it) => it.stamp, 'stamp', _first),
    );
  });

  test('the connection generation comes from the client', () async {
    final transport = StampedPlatformTransport(_Scripted([]));

    expect(await transport.connectionGeneration(), 3);
  });
}
