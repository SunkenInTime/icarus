@Tags(['timing'])
library;

import 'dart:io';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/queue.dart' show derivationWork;
import 'package:test/test.dart';

import 'cloud_support.dart';
import 'support.dart';

typedef Work = ({int visits, int micros});

Work derive(CloudQueue queue) {
  final fresh = CloudQueue(
    entries: queue.entries,
    attempts: queue.attempts,
    landed: queue.landed,
    nextAttempt: queue.nextAttempt,
    nextSession: queue.nextSession,
    shown: queue.shown,
    strategy: queue.strategy,
    session: queue.session,
  );
  derivationWork.reset();
  final clock = Stopwatch()..start();
  entryViews(fresh, now);
  return (visits: derivationWork.visits, micros: clock.elapsedMicroseconds);
}

StrategyRowSet rowsWith(int onB, int onA) => strategyRows(
  elements: [
    for (var i = 0; i < onA; i++) element('a$i'),
    for (var i = 0; i < onB; i++) element('b$i', pageId: 'page-b'),
  ],
);

({Work held, Work live}) measure(
  StrategyRowSet base,
  void Function(Client client) edits,
) {
  Work run(bool trashed) {
    final client = Client(base: base);
    edits(client);
    client.read(
      trashed ? withOp(base, pageDelete('their-drop', 'page-b')) : base,
    );
    return derive(client.queue);
  }

  return (held: run(true), live: run(false));
}

({Work held, Work live}) manyItems(int n) => measure(rowsWith(n, 300), (
  client,
) {
  for (var i = 0; i < n; i++) {
    client.edit(movePatch('b$i', elementId: 'b$i', pageId: 'page-b'));
  }
  for (var i = 0; i < 300; i++) {
    client.edit(movePatch('a$i', elementId: 'a$i'));
  }
});

({Work held, Work live}) manyPageOps(int n) => measure(rowsWith(0, 300), (
  client,
) {
  for (var i = 0; i < n; i++) {
    client.edit(
      PageReorderOp(
        opId: 'move-$i',
        pagePublicId: 'page-b',
        sortIndex: i.isEven ? 0 : 1,
        expectedStrategyRevision: 1 + i,
      ),
    );
  }
  for (var i = 0; i < 300; i++) {
    client.edit(movePatch('a$i', elementId: 'a$i'));
  }
});

({Work held, Work live}) oneItem(int n) => measure(rowsWith(0, 0), (client) {
  client.edit(elementAdd('add', elementId: 'x', pageId: 'page-b'));
  for (var i = 1; i < n; i++) {
    client.edit(movePatch('x$i', elementId: 'x', expected: i, x: i * 1.0));
  }
});

void main() {
  final cases = {
    '300 held ops on 300 items of a trashed page, then 300 on a live page':
        (manyItems, 300),
    '50 held page moves under the strategy key, then 300 on a live page': (
      manyPageOps,
      50,
    ),
    '200 held ops on one item of a trashed page': (oneItem, 200),
  };
  for (final MapEntry(key: name, value: (measured, n)) in cases.entries) {
    test('$name: derivation visits grow no faster than the queue', () {
      final half = measured(n ~/ 2);
      final at = measured(n);
      if (Platform.environment['CLOUD_COST_COUNTS'] == '1') {
        stdout.writeln(
          '$name\n'
          '  n=${n ~/ 2} held ${half.held.visits} visits '
          '${half.held.micros} us, nothing held ${half.live.visits} visits '
          '${half.live.micros} us\n'
          '  n=$n held ${at.held.visits} visits ${at.held.micros} us, '
          'nothing held ${at.live.visits} visits ${at.live.micros} us',
        );
      }
      expect(at.held.visits, lessThanOrEqualTo(at.live.visits * 2));
      expect(at.held.visits, lessThan(half.held.visits * 3));
    });
  }
}
