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
  writtenLongAgo,
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
      WindowClosed() => Kind.windowClosed,
      WrittenLongAgo() => Kind.writtenLongAgo,
      RetriesExhausted() => Kind.retriesExhausted,
      DeleteHeld() => Kind.deleteHeld,
      Oversized() => Kind.oversized,
      ChangedUnseen() => Kind.changedUnseen,
      RowPageGone() => Kind.rowPageGone,
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
    client.must(OpAnswered(attempt, const AppliedAnswer('first', revision: 3)));
    return client..edit(onVisible(client.visible, movePatch('x', x: 70)));
  }),
  Row(
    'page delete waiting for its page after this device\'s work landed where it did not predict',
    () {
      final client = Client()..edit(movePatch('first'));
      final attempt = client.claim(['first']);
      client.must(
        OpAnswered(attempt, const AppliedAnswer('first', revision: 3)),
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
    final client = sentAndLost()..clock = now.add(resendWindow);
    return client..queue = look(client.queue, client.at).queue;
  }),
  Row('needs user: written 29 days ago against a revision, never sent', () {
    final client = Client()..edit(movePatch('x'));
    client.clock = now.add(resendWindow);
    return client..queue = look(client.queue, client.at).queue;
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
        const NoopAnswer('del', revision: 2, replay: NoopReplay.notApplied),
      ),
    );
  }),
  Row('needs user: an edit waiting for a row whose page is gone', () {
    final client = Client()
      ..edit(movePatch('first', merge: FieldMerge(fields: ['position'])));
    final attempt = client.claim(['first']);
    client.must(OpAnswered(attempt, const AppliedAnswer('first', revision: 3)));
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
      '- When the user gives up an entry (takes the cloud\'s version or '
      'discards it), every later entry for the same row, page or strategy '
      'goes with it, because it was built on the work given up.',
    )
    ..writeln(
      '- Results (the rows the server sent) never settle or drop an entry. '
      'They end the drawing of landed work, and they tell a whole-row write '
      'whether its row is as the user saw it. Two results also stop sending: '
      'the page delete below, and a result saying the strategy is gone, '
      'which stops every claim for that strategy.',
    )
    ..writeln()
    ..writeln('## Which revision an op names')
    ..writeln()
    ..writeln(
      'An op names the revision the user\'s edit was made against. The device '
      'keeps, per row, a justified row: a revision with the content at that '
      'revision, compared by content for every row, the strategy included. '
      'Nothing is justified when a session opens. A row becomes justified when '
      'a result of this session shows it, or when this device\'s own op on it '
      'is answered at exactly the revision `applyOp` predicted over a base '
      'that was already justified when the edit was made: either the row a '
      'queued edit ahead of it predicted, or the justified row itself. An '
      'answer of nothing to do at the justified revision of an op that '
      'changes nothing keeps the row justified. Any other answer, nothing to '
      'do at another revision included, means someone else wrote in between: '
      'the row is not justified until a result shows it, and every later edit '
      'of that row loses its justification too. A result never changes the '
      'revision an op names. `_judge` in `lib/src/cloud/queue.dart` is the '
      'only place an outgoing revision is chosen.',
    )
    ..writeln()
    ..writeln(
      '- An op made with nothing of this device\'s ahead of it on its row goes '
      'at its authored revision, and the server decides.',
    )
    ..writeln(
      '- A field merge names its fields and always goes; the server merges '
      'it field by field.',
    )
    ..writeln(
      '- Any other op made behind this device\'s queued or landed work on its '
      'row, a nothing-to-do answer included, goes only once that row is '
      'justified at the revision it names, with the content the user saw (or '
      'already holding what the op writes). Otherwise it waits for the '
      'row\'s result, and needs the user when a result of this session shows '
      'the row otherwise, when a result of its page no longer holds a row '
      'that results showed or this device added, or when its page is gone.',
    )
    ..writeln(
      '- A page add, reorder or delete answers only the strategy revision, so '
      'the pages it renumbers are not justified by the answer: a page rename '
      'behind one waits for a page list.',
    )
    ..writeln(
      '- An undo of a delete goes without asking only over this device\'s '
      'delete answered at the revision it predicted, with the tombstone as '
      'the user saw it, within 29 days of first sending that delete.',
    )
    ..writeln(
      '- An entry that carries a revision check and was written more than 29 '
      'days ago needs the user before it is sent, sent before or not, '
      'because a purged tombstone can come back at revision 1.',
    )
    ..writeln('- Keep mine names the revision the user chose theirs over.')
    ..writeln()
    ..writeln('## The resend window and the sender')
    ..writeln()
    ..writeln(
      '- An answer that never came is sent again under the same op id, in '
      'checked form, until 29 days after the op was first sent; the server '
      'remembers answers for 30. A batch refused whole (upgrade, sign-in, '
      'access) was never tried, so it does not start that clock, even when '
      'the refusal arrives after the attempt was given up. A '
      'transition that finds the 29 days passed records it, even when it '
      'changes nothing else; views show only what was recorded, and `look` '
      'records and returns the views of the queue it returns. Once recorded, '
      'the entry waits for the user and is never sent again.',
    )
    ..writeln(
      '- The queue cannot stop a send it already handed over. The sender '
      'must give an attempt up as unanswered (`TransportFailed`) within '
      '`sendGiveUpAfter` (one hour) of claiming it, well inside the one-day '
      'margin between the queue\'s window and the server\'s memory. An open '
      'attempt shows as sending until the sender does so.',
    )
    ..writeln(
      '- Answered work that the latest results do not show yet is drawn as '
      'landed, in the order the server applied it, off its source page and '
      'on its destination, until a result shows that row at the answered '
      'revision or later. A delete this device made stays known as its own '
      'until a result shows a later revision of the row.',
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
      'saw, or when its content was never read. It goes as soon as a result '
      '(a page list or the page\'s own result) says the page is gone, since '
      'there is nothing left to protect. All of '
      'this lives in '
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
