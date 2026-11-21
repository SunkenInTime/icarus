import 'dart:io';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

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
  retriesExhausted,
  deleteHeld,
  oversized,
  changedUnseen,
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
      WindowClosed() => Kind.windowClosed,
      RetriesExhausted() => Kind.retriesExhausted,
      DeleteHeld() => Kind.deleteHeld,
      Oversized() => Kind.oversized,
      ChangedUnseen() => Kind.changedUnseen,
      RetiredFormat() => Kind.retired,
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
  final client = Client()..edit(movePatch('x'));
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
  Row('a whole write waiting for the result of a landed field merge', () {
    final client = Client()
      ..edit(movePatch('first', merge: FieldMerge(fields: ['position'])));
    final attempt = client.claim(['first']);
    client.must(OpAnswered(attempt, const AppliedAnswer('first', revision: 2)));
    return client..edit(elementDelete('x', expected: 2));
  }),
  Row(
    'page delete waiting for its page to show this device\'s landed work',
    () {
      final client = Client()..edit(movePatch('first'));
      final attempt = client.claim(['first']);
      client.must(
        OpAnswered(attempt, const AppliedAnswer('first', revision: 2)),
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
  Row(
    'needs user: unanswered for 29 days',
    () => sentAndLost()..clock = now.add(resendWindow),
  ),
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
        const NoopAnswer('del', revision: 2, replay: NoopReplay.notApplied),
      ),
    );
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

final events = <String, QueueEvent Function(Client)>{
  'user edits another item': (c) =>
      c.editEvent(movePatch('z', elementId: 'e2')),
  'user edits the same item': (c) =>
      c.editEvent(movePatch('w', expected: 2, x: 30)),
  'claimed': (c) => BatchClaimed(clientId: clientId, opIds: ['x'], at: c.at),
  'claimed under another client id': (c) =>
      BatchClaimed(clientId: 'client-2', opIds: ['x'], at: c.at),
  'attempt 1 released': (c) => const ClaimReleased(1),
  'attempt 1 transport failed': (c) =>
      TransportFailed(1, TransportFailure.network, at: c.at),
  'applied at 2': (c) => const OpAnswered(1, AppliedAnswer('x', revision: 2)),
  'noop at 2, applied when first received': (c) => const OpAnswered(
    1,
    NoopAnswer('x', revision: 2, replay: NoopReplay.appliedWhenFirstReceived),
  ),
  'noop at 2, not applied': (c) => const OpAnswered(
    1,
    NoopAnswer('x', revision: 2, replay: NoopReplay.notApplied),
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
      const OpAnswered(99, AppliedAnswer('x', revision: 2)),
  for (final refusal in BatchRefusal.values)
    'attempt 1 refused whole: ${refusal.name}': (c) => BatchRefused(1, refusal),
  'app restarted, same build': (c) => const AppRestarted(build: build),
  'app restarted, new build': (c) => const AppRestarted(build: 'build-2'),
  'connection lost': (c) => const ConnectionLost(),
  'connection returned': (c) => const ConnectionReturned(),
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
            SendBatch(:final attempt, :final ops) =>
              'sends attempt $attempt (${ops.map((op) => op.opId).join(', ')})',
            SessionOpened(:final session) => 'opens session $session',
            ReportUnauthenticated() => 'reports unauthenticated',
            HoldSendingForUpgrade() => 'holds sending until upgrade',
          },
        ),
      ];
      return parts.isEmpty ? 'unchanged' : parts.join('; ');
  }
}

String renderTable() {
  final out = StringBuffer()
    ..writeln('# Cloud pending op transitions')
    ..writeln()
    ..writeln(
      'Generated by `test/cloud_transitions_test.dart` from `transition` and '
      '`entryViews` in `lib/src/cloud/queue.dart`. Run with '
      '`UPDATE_TRANSITIONS=1` to rewrite.',
    )
    ..writeln()
    ..writeln(
      'Each section builds a queue by real events until op `x` is in that '
      'state, then applies one event. The state and its holds are derived '
      'from the stored facts after every event. Events that do not apply are '
      'listed after the table; the queue is left as it was.',
    )
    ..writeln()
    ..writeln('## Who decides')
    ..writeln()
    ..writeln(
      '- The server\'s answer to an op is the only thing that takes it out of '
      'the queue or hands it to the user. Applied or nothing to do: done. '
      'Rejected: the user decides, and later work on that row waits behind '
      'it, unless the row the rejection carries already holds what the op '
      'wrote. Failed: the user decides.',
    )
    ..writeln(
      '- Results (the latest rows the server sent this session) never hold, '
      'release, settle or drop an entry. They only decide when answered work '
      'stops being drawn on top of them, and whether a whole write made '
      'after a landed field merge still matches the row the user saw. The '
      'page delete below is the one exception.',
    )
    ..writeln(
      '- An answer that never came is sent again under the same op id, in '
      'checked form, until 29 days after the op was first sent; the server '
      'remembers answers for 30. When the 29 days pass that is recorded, and '
      'the entry waits for the user and is never sent again.',
    )
    ..writeln(
      '- Answered work that the latest results do not show yet is drawn as '
      'landed: an answer that names a whole row updates it, and a field '
      'merge, page add, page reorder or page delete is drawn until a result '
      'shows that row at the answered revision or later. Landed work never '
      'authors a send: a whole write on a row behind a landed field merge, or '
      'a page rename behind a landed page renumbering, waits for the result '
      'and then needs the user unless that row is as the user saw it.',
    )
    ..writeln()
    ..writeln('## Folding')
    ..writeln()
    ..writeln(
      'A field edit folds into an earlier field edit of the same row only '
      'when the earlier one is unsent and unclaimed, both name exactly the '
      'same fields, and nothing else for that row is queued between them. The '
      'folded edit is not exactly the two sent in turn in two corners:',
    )
    ..writeln()
    ..writeln(
      '- The server already holds the first edit\'s value. Sending both is a '
      'no-op then an applied edit; the folded edit is a field conflict and '
      'needs the user, with the server\'s value and the user\'s value both '
      'kept.',
    )
    ..writeln(
      '- The server already holds the later edit\'s value where the first '
      'would conflict. Sending both holds the first for the user; the folded '
      'edit lands and the server ends at the user\'s last value for every '
      'field it names.',
    )
    ..writeln()
    ..writeln(
      '`test/cloud_fold_test.dart` requires every other case to give what '
      'sending both gives.',
    )
    ..writeln()
    ..writeln('## The page delete exception, until #670')
    ..writeln()
    ..writeln(
      'The server guards a page delete by the strategy\'s revision only, so a '
      'page delete can land after a teammate added an element to the page '
      '([#670](https://github.com/SunkenInTime/icarus/issues/670)). Until the '
      'server checks the page itself, a page delete waits for a result of its '
      'page and needs the user when that page no longer holds what the user '
      'saw, or when its content was never read. It goes when the page is '
      'already gone. All of this lives in '
      '`lib/src/cloud/held_page_delete.dart` and comes out in one piece when '
      '#670 lands.',
    );
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
        expect(transition(client.queue, event, now: client.at), isA<Step>());
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

  test('the table in $tablePath is the one the code gives', () {
    final rendered = renderTable();
    final file = File(tablePath);
    if (Platform.environment['UPDATE_TRANSITIONS'] == '1') {
      file.writeAsStringSync(rendered);
    }
    expect(file.readAsStringSync(), rendered);
  });
}
