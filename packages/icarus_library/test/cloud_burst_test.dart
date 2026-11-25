import 'dart:io';
import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_support.dart';
import 'support.dart';

final class Burst {
  Burst({
    required this.folding,
    required this.online,
    required this.seed,
    required this.switchEvery,
  }) : random = Random(seed);

  final bool folding;
  final bool online;
  final int? switchEvery;
  final int seed;
  final Random random;
  final client = Client();
  StrategyRowSet server = initialRows();
  int received = 0;
  int nextId = 0;
  int? open;
  int gestureKind = 0;

  StrategyOp gesture() {
    final row = client.visible.element('e1')! as LiveElement;
    final data = {...row.payload.data.toJson()};
    final String field;
    if (switchEvery case final every? when random.nextInt(every) == 0) {
      gestureKind = random.nextInt(3);
    }
    switch (gestureKind) {
      case 0:
        field = 'position';
        data[field] = {'dx': random.nextInt(500), 'dy': random.nextInt(500)};
      case 1:
        field = 'rotation';
        data[field] = random.nextInt(360);
      case _:
        field = 'scale';
        data[field] = 1 + random.nextInt(4);
    }
    return ElementPatchOp(
      opId: 'op${nextId++}',
      elementPublicId: 'e1',
      expectedElementRevision: row.revision,
      payload: agentPayload('e1', data),
      sortIndex: row.sortIndex,
      merge: FieldMerge(fields: [field]),
    );
  }

  void edit() {
    final event = client.editEvent(gesture());
    final before = client.queue;
    final result = transition(before, event, now: now);
    if (!folding &&
        result is Stepped &&
        result.effects.any(
          (effect) => effect is OpRemoved && effect.cause is FoldedInto,
        )) {
      final edit = (event as UserEdited).edit;
      client.queue = CloudQueue(
        entries: [
          ...before.entries,
          PendingOp(
            place: before.entries.last.place + 1,
            work: OpWork(edit.op),
            scope: edit.scope,
            authored: edit.authored,
            authoredIn: before.session.number,
            authoredAt: now,
            refusal: const NotRefused(),
            retriedAfter: before.nextAttempt - 1,
          ),
        ],
        attempts: before.attempts,
        landed: before.landed,
        nextAttempt: before.nextAttempt,
        nextSession: before.nextSession,
        shown: before.shown,
        strategy: before.strategy,
        session: before.session,
      );
      return;
    }
    client.queue = stepped(result).queue;
  }

  void sendWhatCanGo() {
    final views = entryViews(client.queue, now);
    final ids = [
      for (final entry in client.queue.entries)
        if (views[entry.id]?.sendable ?? false) entry.id,
    ];
    if (ids.isEmpty) return;
    open = client.claim(ids);
  }

  void answerOpen() {
    final attempt = open;
    if (attempt == null) return;
    open = null;
    for (final op in client.queue.attempts[attempt]!.ops) {
      received++;
      final answer = switch (applyOp(server, op)) {
        final OpApplied done => () {
          server = server.withRows(done.rows);
          return AppliedAnswer(
            op.opId,
            revision: visibleRevision(server, op)!,
            life: fixtureLife,
          );
        }(),
        OpUnchanged() => NoopAnswer(
          op.opId,
          revision: visibleRevision(server, op)!,
          replay: NoopReplay.notApplied,
          life: fixtureLife,
        ),
        final OpRefused refused => throw StateError(
          'a burst op was refused: ${refused.refusal}',
        ),
      };
      client.must(OpAnswered(attempt, answer, point: tick()));
    }
    client.read(server, pages: ['page-a']);
  }

  void run() {
    if (online) client.must(reconnected());
    final length = 2 + random.nextInt(19);
    final claimAt = random.nextInt(length);
    for (var i = 0; i < length; i++) {
      edit();
      if (i == claimAt) sendWhatCanGo();
    }
    answerOpen();
    while (client.queue.entries.isNotEmpty) {
      sendWhatCanGo();
      if (open == null) break;
      answerOpen();
    }
    if (client.queue.entries.isNotEmpty) {
      throw StateError('the burst did not drain: ${client.queue.entries}');
    }
  }
}

Map<String, int> measure({required int? switchEvery}) {
  final totals = <String, int>{};
  for (final online in [true, false]) {
    for (final folding in [true, false]) {
      var ops = 0;
      var edits = 0;
      for (var seed = 1; seed <= 300; seed++) {
        final burst = Burst(
          folding: folding,
          online: online,
          seed: seed,
          switchEvery: switchEvery,
        )..run();
        ops += burst.received;
        edits += burst.nextId;
      }
      totals['${online ? 'online' : 'offline'} '
              '${folding ? 'folding' : 'no folding'}'] =
          ops;
      totals['${online ? 'online' : 'offline'} edits'] = edits;
    }
  }
  if (Platform.environment['CLOUD_BURST_COUNTS'] == '1') {
    stdout.writeln(
      switchEvery == null
          ? 'one gesture per burst: $totals'
          : 'gesture changes about every $switchEvery edits: $totals',
    );
  }
  return totals;
}

void main() {
  test('a nudge burst on one item folds into few ops', () {
    final totals = measure(switchEvery: null);
    for (final mode in ['online', 'offline']) {
      expect(
        totals['$mode folding']! * 3,
        lessThan(totals['$mode no folding']!),
      );
    }
  });

  test('a burst that changes gesture still drains and folds no worse', () {
    final totals = {
      for (final every in [8, 1])
        for (final MapEntry(:key, :value) in measure(
          switchEvery: every,
        ).entries)
          '$every $key': value,
    };
    for (final mode in [
      for (final every in [8, 1]) '$every online',
      for (final every in [8, 1]) '$every offline',
    ]) {
      expect(
        totals['$mode folding']!,
        lessThanOrEqualTo(totals['$mode no folding']!),
      );
    }
  });
}
