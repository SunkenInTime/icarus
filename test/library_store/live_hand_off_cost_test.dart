import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/library_store/call_governor.dart';
import 'package:icarus/library_store/library_store_open.dart' show appCanRead;
import 'package:icarus_library/icarus_library.dart';

import '../collab/stamped_over.dart';
import 'sender_world.dart';
import 'server_fixtures.dart' show servedAccount, strategyId;

const heavyItems = 3000;
const runs = 20;

Map<String, Object?> wire(Map<String, dynamic> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

Map<String, Object?> elementRow(int n) {
  final at = Offset(60.0 + (n % 40) * 22, 60.0 + (n ~/ 40) * 22);
  final (kind, data) = n.isEven
      ? (
          'agent',
          PlacedAgent(id: 'fill-$n', type: AgentType.jett, position: at)
              .toJson(),
        )
      : (
          'text',
          (PlacedText(id: 'fill-$n', position: at)..text = 'Fill $n').toJson(),
        );
  return {
    'publicId': 'fill-${n.toString().padLeft(5, '0')}',
    'strategyPublicId': strategyId,
    'pagePublicId': 'heavy',
    'elementType': kind,
    'payload': wire(cloudElementPayload(kind: kind, data: wire(data))),
    'sortIndex': n,
    'revision': 1,
    'deleted': false,
    'createdAt': 1700000000000.0 + n,
    'updatedAt': 1700000000000.0 + n,
  };
}

ConvexValue heavyAnswer() => ConvexValue.fromDart({
      'page': {
        'publicId': 'heavy',
        'strategyPublicId': strategyId,
        'name': 'Heavy',
        'sortIndex': 0,
        'isAttack': true,
        'revision': 1,
        'createdAt': 1700000000000.0,
        'updatedAt': 1700000000000.0,
      },
      'content': {
        'settings': null,
        'revision': 1,
        'createdAt': 1700000000000.0,
        'updatedAt': 1700000000000.0,
      },
      'elements': [for (var n = 0; n < heavyItems; n++) elementRow(n)],
      'lineups': const <Object?>[],
      'assets': const <Object?>[],
    });

final class _Answers implements ConvexTransport {
  _Answers(this.answer);

  final ConvexValue answer;

  @override
  Stream<ConvexValue> subscribe(String name, ConvexObject args) =>
      Stream.value(answer);

  @override
  Stream<List<ConvexValue>> subscribeTogether(
    List<(String, ConvexObject)> queries,
  ) =>
      throw UnimplementedError('subscribeTogether');

  @override
  Future<ConvexValue> query(String name, ConvexObject args) =>
      throw UnimplementedError(name);

  @override
  Future<ConvexValue> mutation(String name, ConvexObject args) =>
      throw UnimplementedError(name);

  @override
  Future<ConvexValue> action(String name, ConvexObject args) =>
      throw UnimplementedError(name);
}

void main() {
  test(
      'the store\'s part of one live answer of the driver\'s heavy page: '
      'converting it to a result and handing it to the sender', () async {
    final answer = await ConvexStrategyRepository.stamped(
      StampedOver(_Answers(heavyAnswer())),
    )
        .watchPageSnapshotStamped(
          strategyPublicId: strategyId,
          pagePublicId: 'heavy',
          accountSubject: servedAccount.subject,
        )
        .first;
    expect(
      switch (answer) {
        StampedValue(:final value) => value.elements.length,
        StampedError() => 0,
      },
      heavyItems,
    );

    final micros = <int>[];
    inWorld((world) {
      const subject = ReadOfPage('heavy');
      world.sender.liveOpened(strategyId, subject);
      for (var run = 0; run <= runs; run++) {
        final watch = Stopwatch()..start();
        final outcome = pageOutcomeOf(
          answer,
          pagePublicId: 'heavy',
          canRead: appCanRead,
        );
        world.sender.liveArrived(strategyId, subject, servedAccount, outcome);
        watch.stop();
        expect(
          outcome,
          isA<StoreReadAnswered>().having(
            (read) => (read.base as PageRead).elements.length,
            'elements',
            heavyItems,
          ),
        );
        if (run > 0) micros.add(watch.elapsedMicroseconds);
      }
    }, addStrategy: false);

    micros.sort();
    final median = (micros[runs ~/ 2 - 1] + micros[runs ~/ 2]) / 2;
    printOnFailure('$micros');
    debugPrint('heavy page ($heavyItems items): store hand-off median '
        '${(median / 1000).toStringAsFixed(2)} ms over $runs runs, '
        'fastest ${(micros.first / 1000).toStringAsFixed(2)} ms, slowest '
        '${(micros.last / 1000).toStringAsFixed(2)} ms');
  });
}
