import 'dart:io';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_server.dart';
import 'cloud_support.dart';
import 'support.dart';

const tablePath = 'doc/cloud_transitions.md';

enum Kind {
  waiting,
  heldBehindEntry,
  awaitingRowResult,
  awaitingPageResult,
  sending,
  unansweredUntilRetry,
  unansweredReady,
  rejected,
  failed,
  windowClosed,
  madeInReplacedStrategy,
  retriesExhausted,
  deleteHeld,
  oversized,
  changedUnseen,
  rowPageGone,
  retired,
}

Kind kindOf(QueueEntry entry, EntryView? view) => switch ((entry, view)) {
  (RetiredOp(), _) => Kind.retired,
  (PendingOp(), null) => throw StateError('a pending op always has a view'),
  (PendingOp(), final EntryView view) => switch (view.state) {
    Sending() => Kind.sending,
    NeedsUser(:final reason) => switch (reason) {
      RefusedByServer(refusal: RejectedByServer()) => Kind.rejected,
      RefusedByServer(refusal: FailedOnServer()) => Kind.failed,
      WindowClosed() ||
      RefusedByServer(refusal: AnsweredWithoutLife()) => Kind.windowClosed,
      RetriesExhausted() => Kind.retriesExhausted,
      DeleteHeld() => Kind.deleteHeld,
      Oversized() => Kind.oversized,
      ChangedUnseen() => Kind.changedUnseen,
      RowPageGone() => Kind.rowPageGone,
      RetiredFormat() => Kind.retired,
      MadeInAReplacedStrategy() => Kind.madeInReplacedStrategy,
    },
    Waiting() || Unanswered()
        when view.holds.any((hold) => hold is BehindEntry) =>
      Kind.heldBehindEntry,
    Waiting() || Unanswered()
        when view.holds.any(
          (hold) => hold is AwaitingResult && hold.subject is RowResult,
        ) =>
      Kind.awaitingRowResult,
    Waiting() || Unanswered()
        when view.holds.any(
          (hold) => hold is AwaitingResult && hold.subject is PageResult,
        ) =>
      Kind.awaitingPageResult,
    Unanswered() when view.holds.any((hold) => hold is UntilRetryTime) =>
      Kind.unansweredUntilRetry,
    Unanswered() => Kind.unansweredReady,
    Waiting() => Kind.waiting,
  },
};

final class Row {
  Row(this.label, this.build, {this.subject = 'x'});

  final String label;
  final Client Function() build;
  final String subject;
}

Client sentAndLost() {
  final client = Client()..edit(elementAdd('x'));
  final attempt = client.claim(['x']);
  return client
    ..must(TransportFailed(attempt, TransportFailure.network, at: now));
}

Client answered(OpAnswer answer, {StrategyOp? op}) {
  final client = Client()..edit(op ?? movePatch('x'));
  final attempt = client.claim(['x']);
  return client..must(OpAnswered(attempt, answer));
}

ElementAddOp putBack(String opId, StrategyRows rows) {
  final row = rows.element('e1')! as LiveElement;
  return ElementAddOp(
    opId: opId,
    elementPublicId: 'e1',
    pagePublicId: row.pagePublicId,
    payload: row.payload,
    sortIndex: row.sortIndex,
    expectedElementRevision: row.revision + 1,
  );
}

final rows = <Row>[
  Row('waiting, nothing ahead of it', () => Client()..edit(movePatch('x'))),
  Row('held behind an earlier edit of the row', () {
    final client = Client()..edit(movePatch('first'));
    client.claim(['first']);
    return client..edit(movePatch('x', expected: 2, x: 30));
  }),
  Row('a whole write behind a merge that landed where this device did not '
      'predict, waiting for the row\'s result', () {
    final client = Client()
      ..edit(movePatch('first', merge: FieldMerge(fields: ['position'])));
    final attempt = client.claim(['first']);
    client.must(
      OpAnswered(
        attempt,
        const AppliedAnswer('first', revision: 3, life: fixtureLife),
      ),
    );
    return client..edit(onVisible(client.visible, movePatch('x', x: 70)));
  }),
  Row(
    'page delete waiting for its page after this device\'s work landed where it did not predict',
    () {
      final client = Client()..edit(movePatch('first'));
      final attempt = client.claim(['first']);
      client.must(
        OpAnswered(
          attempt,
          const AppliedAnswer('first', revision: 3, life: fixtureLife),
        ),
      );
      return client..edit(pageDelete('x', 'page-a'));
    },
  ),
  Row('sending in attempt 1', () {
    final client = Client()..edit(movePatch('x'));
    client.claim(['x']);
    return client;
  }),
  Row('unanswered, waiting for its retry time', sentAndLost),
  Row(
    'unanswered, ready to send again',
    () => sentAndLost()..clock = now.add(const Duration(minutes: 1)),
  ),
  Row(
    'needs user: rejected with revision_mismatch',
    () => answered(
      const RejectedAnswer(
        'x',
        RejectionReason.revisionMismatch,
        NoServerCopy(),
      ),
    ),
  ),
  Row(
    'needs user: failed on the server with PAGE_DELETED',
    () => answered(
      const FailedAnswer('x', KnownFailure(FailureCode.pageDeleted), 'deleted'),
    ),
  ),
  Row('needs user: unanswered for 29 days', () {
    final client = sentAndLost()..clock = now.add(const Duration(days: 29));
    return client..queue = look(client.queue, client.at).queue;
  }),
  Row('needs user: made in a strategy deleted and made again since', () {
    final client = Client()..edit(movePatch('x'));
    return client..read(reuploaded(initialRows(), fixtureLife + 1000));
  }),
  Row('needs user: retries exhausted', () {
    final client = Client()..edit(movePatch('x'));
    for (var i = 0; i < retriesBeforePause; i++) {
      final attempt = client.claim(['x']);
      client.must(TransportFailed(attempt, TransportFailure.network, at: now));
      client.clock = now.add(Duration(minutes: i + 1));
    }
    return client..clock = null;
  }),
  Row('needs user: page delete held, page changed (until #670)', () {
    final client = Client()..edit(pageDelete('x', 'page-a'));
    return client..read(withOp(initialRows(), movePatch('t', rotation: 90)));
  }),
  Row('needs user: oversized', () {
    return Client()..edit(
      ElementPatchOp(
        opId: 'x',
        elementPublicId: 'e1',
        expectedElementRevision: 1,
        payload: agentPayload('e1', {'points': List.filled(8001, 0)}),
      ),
    );
  }),
  Row('needs user: a put-back after someone else deleted the row', () {
    final client = Client();
    final drawn = client.visible;
    client
      ..edit(elementDelete('del'))
      ..edit(putBack('x', drawn));
    final attempt = client.claim(['del']);
    return client..must(
      OpAnswered(
        attempt,
        const NoopAnswer(
          'del',
          revision: 2,
          replay: NoopReplay.notApplied,
          life: fixtureLife,
        ),
      ),
    );
  }),
  Row('needs user: an edit waiting for a row whose page is gone', () {
    final client = Client()
      ..edit(movePatch('first', merge: FieldMerge(fields: ['position'])));
    final attempt = client.claim(['first']);
    client.must(
      OpAnswered(
        attempt,
        const AppliedAnswer('first', revision: 3, life: fixtureLife),
      ),
    );
    client.edit(onVisible(client.visible, movePatch('x', x: 70)));
    return client..arrive(const PageGone('page-a'));
  }),
  Row('a format this build no longer sends', () {
    final client = Client();
    client.queue = CloudQueue(
      entries: [
        RetiredOp(
          place: 0,
          opId: 'x',
          clientId: clientId,
          landing: Landing.mayHaveLanded,
          stored: const {'type': 'lineup.link.add'},
        ),
      ],
      attempts: const {},
      landed: const [],
      nextAttempt: 1,
      nextSession: client.queue.nextSession,
      shown: client.queue.shown,
      strategy: StrategyFacts.fresh,
      session: client.queue.session,
    );
    return client;
  }),
  Row('waiting, strategy deleted on the server', () {
    return Client()
      ..edit(movePatch('x'))
      ..arrive(const StrategyGone());
  }),
  Row('waiting, edit access lost', () {
    final client = Client()
      ..edit(movePatch('x'))
      ..edit(movePatch('y', elementId: 'e2'));
    final attempt = client.claim(['y']);
    return client..must(BatchRefused(attempt, BatchRefusal.editAccessRemoved));
  }),
  Row('waiting, upgrade required', () {
    final client = Client()
      ..edit(movePatch('x'))
      ..edit(movePatch('y', elementId: 'e2'));
    final attempt = client.claim(['y']);
    return client..must(BatchRefused(attempt, BatchRefusal.upgradeRequired));
  }),
];

String lifeName(int life) => life == fixtureLife
    ? 'L0'
    : 'L0${life > fixtureLife ? '+' : ''}${life - fixtureLife}';

QueueEvent? editOfShown(Client client, String elementId, StrategyOp op) =>
    client.visible.element(elementId) == null ? null : client.editEvent(op);

final events = <String, QueueEvent? Function(Client)>{
  'user edits another item': (c) =>
      editOfShown(c, 'e2', movePatch('z', elementId: 'e2')),
  'user edits the same item': (c) =>
      editOfShown(c, 'e1', movePatch('w', expected: 2, x: 30)),
  'claimed': (c) => BatchClaimed(clientId: clientId, opIds: ['x'], at: c.at),
  'claimed under another client id': (c) =>
      BatchClaimed(clientId: 'client-2', opIds: ['x'], at: c.at),
  'attempt 1 released': (c) => const ClaimReleased(1),
  'attempt 1 transport failed': (c) =>
      TransportFailed(1, TransportFailure.network, at: c.at),
  'applied at 2': (c) =>
      const OpAnswered(1, AppliedAnswer('x', revision: 2, life: fixtureLife)),
  'noop at 2, applied when first received': (c) => const OpAnswered(
    1,
    NoopAnswer(
      'x',
      revision: 2,
      replay: NoopReplay.appliedWhenFirstReceived,
      life: fixtureLife,
    ),
  ),
  'noop at 2, not applied': (c) => const OpAnswered(
    1,
    NoopAnswer(
      'x',
      revision: 2,
      replay: NoopReplay.notApplied,
      life: fixtureLife,
    ),
  ),
  'noop without a revision': (c) =>
      const OpAnswered(1, NoopWithoutRevision('x')),
  for (final reason in RejectionReason.values)
    'rejected: ${reason.wireName}': (c) =>
        OpAnswered(1, RejectedAnswer('x', reason, const NoServerCopy())),
  'failed: INTERNAL_ERROR': (c) => const OpAnswered(
    1,
    FailedAnswer('x', OtherFailure('INTERNAL_ERROR'), 'unexpected'),
  ),
  'answer from an attempt that did not hold it': (c) =>
      const OpAnswered(99, AppliedAnswer('x', revision: 2, life: fixtureLife)),
  for (final refusal in BatchRefusal.values)
    'attempt 1 refused whole: ${refusal.name}': (c) => BatchRefused(1, refusal),
  'app restarted, same build': (c) => const AppRestarted(build: build),
  'app restarted, new build': (c) => const AppRestarted(build: 'build-2'),
  'connection lost': (c) => const ConnectionLost(),
  'connection returned': (c) => const ConnectionReturned(),
  'server time held': (c) => ServerTimeHeld(
    1764000000000,
    at: Duration.zero,
    session: c.queue.session.number,
  ),
  'account changed': (c) => const AccountChanged(),
  'edit access confirmed after attempt 5': (c) =>
      const EditAccessConfirmed(afterAttempt: 5),
  'user: retry': (c) => const UserRetried('x'),
  'user: keep mine, same item': (c) => UserKeptMine(
    'x',
    movePatch('x2', expected: 1),
    authored: authoredFor(c.base, movePatch('x2')),
  ),
  'user: use cloud': (c) => const UserUsedCloud('x'),
  'user: delete anyway': (c) => const UserDeletedAnyway('x'),
  'user: discard': (c) => const UserDiscarded('x'),
  'result: header as it is': (c) =>
      BaseArrived(headerReadOf(c.base), session: c.queue.session.number),
  'result: page-a with the item at revision 2': (c) => BaseArrived(
    PageRead(
      page: page('page-a', sortIndex: 0),
      elements: [element('e1', revision: 2), element('e2')],
      lineupGroups: const [],
    ),
    session: c.queue.session.number,
  ),
  'result: page-a with the item as this device wrote it at 2': (c) =>
      BaseArrived(
        pageReadOf(withOp(initialRows(), movePatch('m')), 'page-a'),
        session: c.queue.session.number,
      ),
  'result: page-a from a session that ended': (c) => BaseArrived(
    pageReadOf(initialRows(), 'page-a'),
    session: c.queue.session.number - 1,
  ),
  'result: page-b gone': (c) =>
      BaseArrived(const PageGone('page-b'), session: c.queue.session.number),
  'result: strategy gone': (c) =>
      BaseArrived(const StrategyGone(), session: c.queue.session.number),
};

String describe(Client client, String id) {
  final entry = client.queue.entry(id);
  if (entry == null) return 'gone';
  final view = entryViews(client.queue, client.at)[id];
  return switch (entry) {
    PendingOp() =>
      '${view!.state}${view.holds.isEmpty ? '' : ', ${view.holds.join(', ')}'}',
    RetiredOp() => 'retired format',
  };
}

String outcome(Client before, Step result) {
  switch (result) {
    case NotApplicable():
      return '';
    case Stepped(:final queue, :final effects):
      final after = Client()
        ..base = before.base
        ..clock = before.clock
        ..queue = queue;
      final ids = {
        for (final entry in before.queue.entries) entry.id,
        for (final entry in queue.entries) entry.id,
      };
      final parts = <String>[
        for (final id in ids)
          if (describe(before, id) != describe(after, id))
            '$id: ${describe(after, id)}',
        if (queue.shown.listOwed && !before.queue.shown.listOwed)
          'owes a read of the strategy',
        for (final page in queue.shown.pagesOwed)
          if (!before.queue.shown.pagesOwed.contains(page))
            'owes a read of $page',
        if (standingOf(queue) != standingOf(before.queue))
          'standing ${standingOf(queue).name}',
        for (final work in queue.landed)
          if (!before.queue.landed.contains(work))
            'draws ${work.op.opId} as landed at ${work.revision} '
                '(${work.shape.name})',
        for (final work in before.queue.landed)
          if (!queue.landed.contains(work))
            'stops drawing ${work.op.opId} as landed',
        ...effects.map(
          (effect) => switch (effect) {
            OpRemoved(:final opId, :final cause) => 'removes $opId ($cause)',
            SendBatch(
              :final attempt,
              :final ops,
              :final strategyLife,
              :final lives,
            ) =>
              'sends attempt $attempt '
                  '(${ops.map((op) => switch (lives[op.opId]) {
                    final life? => '${op.opId} on ${lifeName(life)}',
                    null => op.opId,
                  }).join(', ')}) '
                  'in strategy ${lifeName(strategyLife)}',
            SessionOpened(:final session) => 'opens session $session',
            ReportUnauthenticated() => 'reports unauthenticated',
            HoldSendingForUpgrade() => 'holds sending until upgrade',
          },
        ),
      ];
      return parts.isEmpty ? 'unchanged' : parts.join('; ');
  }
}

const generatedMarker =
    '<!-- Generated below by test/cloud_transitions_test.dart. -->';

String renderTable() {
  final out = StringBuffer();
  for (final row in rows) {
    final client = row.build();
    out
      ..writeln()
      ..writeln('## ${row.label}')
      ..writeln()
      ..writeln('Starts as: ${describe(client, row.subject)}.')
      ..writeln()
      ..writeln('| Event | Result |')
      ..writeln('| --- | --- |');
    final ignored = <String>[];
    for (final MapEntry(key: name, value: make) in events.entries) {
      final fresh = row.build();
      final event = make(fresh);
      if (event == null) {
        ignored.add(name);
        continue;
      }
      final result = outcome(
        fresh,
        transition(fresh.queue, event, now: fresh.at),
      );
      if (result.isEmpty) {
        ignored.add(name);
      } else {
        out.writeln('| $name | $result |');
      }
    }
    out
      ..writeln()
      ..writeln('Does not apply: ${ignored.join('; ')}.');
  }
  return out.toString();
}

void main() {
  test('every row answers every event without throwing', () {
    for (final row in rows) {
      for (final make in events.values) {
        final client = row.build();
        final event = make(client);
        if (event == null) continue;
        expect(
          () => transition(client.queue, event, now: client.at),
          returnsNormally,
        );
      }
    }
  });

  test('every kind of entry and every standing the queue can reach has a '
      'row', () {
    final kinds = <Kind>{};
    final standings = <Standing>{};
    for (final row in rows) {
      final client = row.build();
      final views = entryViews(client.queue, client.at);
      kinds.add(kindOf(client.queue.entry(row.subject)!, views[row.subject]));
      standings.add(standingOf(client.queue));
    }
    expect(kinds, Kind.values.toSet());
    expect(standings, {
      for (final standing in Standing.values)
        if (standing != Standing.held) standing,
    });
  });

  test('the tables in $tablePath are the ones the code gives', () {
    final rendered = renderTable();
    final file = File(tablePath);
    final stored = file.readAsStringSync();
    final at = stored.indexOf(generatedMarker);
    expect(at, isNonNegative, reason: 'the marker is missing');
    final header = stored.substring(0, at + generatedMarker.length);
    if (Platform.environment['UPDATE_TRANSITIONS'] == '1') {
      file.writeAsStringSync('$header\n$rendered');
      return;
    }
    expect(stored.substring(header.length + 1), rendered);
  });
}
