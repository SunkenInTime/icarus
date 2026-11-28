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
  refusedAsPageDeleted,
  retired,
}

Kind kindOf(QueueEntry entry, EntryView? view) => switch ((entry, view)) {
  (RetiredOp(), _) => Kind.retired,
  (PendingOp(), null) => throw StateError('a pending op always has a view'),
  (PendingOp(), final EntryView view) => switch (view.state) {
    Sending() => Kind.sending,
    NeedsUser(:final reason) => switch (reason) {
      RefusedByServer(refusal: RejectedByServer()) ||
      ChangedSinceDrawn() => Kind.rejected,
      RefusedByServer(refusal: FailedOnServer()) => Kind.failed,
      RefusedByServer(refusal: AnsweredWithoutLife()) => Kind.windowClosed,
      WindowClosed() => Kind.windowClosed,
      WrittenLongAgo() => Kind.writtenLongAgo,
      RetriesExhausted() => Kind.retriesExhausted,
      DeleteHeld() => Kind.deleteHeld,
      Oversized() => Kind.oversized,
      ChangedUnseen() => Kind.changedUnseen,
      RefusedAsPageDeleted() => Kind.refusedAsPageDeleted,
      RetiredFormat() => Kind.retired,
    },
    Waiting() || Unanswered() || RefusedAgain()
        when view.holds.any((hold) => hold is BehindEntry) =>
      Kind.heldBehindEntry,
    Waiting() || Unanswered() || RefusedAgain()
        when view.holds.any(
          (hold) => hold is AwaitingResult && hold.subject is RowResult,
        ) =>
      Kind.awaitingRowResult,
    Waiting() || Unanswered() || RefusedAgain()
        when view.holds.any(
          (hold) => hold is AwaitingResult && hold.subject is PageResult,
        ) =>
      Kind.awaitingPageResult,
    Unanswered() when view.holds.any((hold) => hold is UntilRetryTime) =>
      Kind.unansweredUntilRetry,
    Unanswered() => Kind.unansweredReady,
    Waiting() || RefusedAgain() => Kind.waiting,
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
  return client..must(OpAnswered(attempt, answer, point: tick()));
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
        point: tick(),
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
          point: tick(),
        ),
      );
      return client..edit(pageDelete('x', 'page-a'));
    },
  ),
  Row('nothing queued, the page list owed', () {
    final client = Client()
      ..edit(
        const StrategyPatchOp(
          opId: 'x',
          expectedStrategyRevision: 1,
          name: 'Renamed',
        ),
      );
    final attempt = client.claim(['x']);
    return client
      ..must(
        OpAnswered(
          attempt,
          const RejectedAnswer(
            'x',
            RejectionReason.rowReplaced,
            NoServerCopy(),
          ),
          point: tick(),
        ),
      )
      ..must(const UserDiscarded('x'));
  }),
  Row('refused whole as STRATEGY_REPLACED, waiting for a page list of a '
      'later strategy life', () {
    final client = Client()..edit(movePatch('x'));
    final attempt = client.claim(['x']);
    return client..must(
      BatchRefused(attempt, BatchRefusal.strategyReplaced, point: tick()),
    );
  }),
  Row('set aside after the strategy was replaced', () {
    final client = Client()..edit(movePatch('x'));
    return client..arrive(
      headerReadOf(
        StrategyRowSet(
          strategy: strategyRow(
            createdAt: strategyCreatedAt.add(const Duration(days: 1)),
          ),
          pages: client.base.pages,
          settings: client.base.settings,
          elements: const [],
          lineupGroups: const [],
        ),
      ),
    );
  }),
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
    'needs user: failed on the server with INTERNAL_ERROR',
    () => answered(
      FailedAnswer('x', OtherFailure('INTERNAL_ERROR'), 'unexpected'),
    ),
  ),
  Row(
    'needs user: refused because its page was deleted',
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
    return client..read(
      withOp(
        withOp(initialRows(), movePatch('t', rotation: 45)),
        movePatch('u', expected: 2, rotation: 90),
      ),
    );
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
        point: tick(),
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
    return client..must(
      BatchRefused(attempt, BatchRefusal.editAccessRemoved, point: tick()),
    );
  }),
  Row('waiting, upgrade required', () {
    final client = Client()
      ..edit(movePatch('x'))
      ..edit(movePatch('y', elementId: 'e2'));
    final attempt = client.claim(['y']);
    return client..must(
      BatchRefused(attempt, BatchRefusal.upgradeRequired, point: tick()),
    );
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
  'applied at 2': (c) => OpAnswered(
    1,
    AppliedAnswer('x', revision: 2, life: fixtureLife),
    point: tick(),
  ),
  'noop at 2, applied when first received': (c) => OpAnswered(
    1,
    NoopAnswer(
      'x',
      revision: 2,
      replay: NoopReplay.appliedWhenFirstReceived,
      life: fixtureLife,
    ),
    point: tick(),
  ),
  'noop at 2, not applied': (c) => OpAnswered(
    1,
    NoopAnswer(
      'x',
      revision: 2,
      replay: NoopReplay.notApplied,
      life: fixtureLife,
    ),
    point: tick(),
  ),
  'noop without a revision': (c) =>
      OpAnswered(1, NoopWithoutRevision('x'), point: tick()),
  'answered at 2 with no life': (c) =>
      OpAnswered(1, AnswerWithoutLife('x', revision: 2), point: tick()),
  for (final reason in RejectionReason.values)
    'rejected: ${reason.wireName}': (c) => OpAnswered(
      1,
      RejectedAnswer('x', reason, const NoServerCopy()),
      point: tick(),
    ),
  'failed: PAGE_DELETED': (c) => OpAnswered(
    1,
    const FailedAnswer('x', KnownFailure(FailureCode.pageDeleted), 'deleted'),
    point: tick(),
  ),
  'failed: INTERNAL_ERROR': (c) => OpAnswered(
    1,
    FailedAnswer('x', OtherFailure('INTERNAL_ERROR'), 'unexpected'),
    point: tick(),
  ),
  'answer from an attempt that did not hold it': (c) => OpAnswered(
    99,
    AppliedAnswer('x', revision: 2, life: fixtureLife),
    point: tick(),
  ),
  for (final refusal in BatchRefusal.values)
    'attempt 1 refused whole: ${refusal.name}': (c) =>
        BatchRefused(1, refusal, point: tick()),
  'app restarted, same build': (c) => const AppRestarted(build: build),
  'app restarted, new build': (c) => const AppRestarted(build: 'build-2'),
  'connection lost': (c) => const ConnectionLost(),
  'connection returned': (c) => reconnected(),
  'server time held': (c) => ServerTimeHeld(
    1764000000000,
    at: Duration.zero,
    session: c.queue.session.number,
    point: lastPoint,
  ),
  'account changed': (c) => const AccountChanged(),
  'edit access confirmed after attempt 5': (c) => EditAccessConfirmed(
    afterAttempt: 5,
    session: c.queue.session.number,
    point: tick(),
  ),
  'user: retry': (c) => const UserRetried('x'),
  'user: keep mine, same item': (c) => UserKeptMine(
    'x',
    movePatch('x2', expected: 1),
    authored: authoredFor(c.base, movePatch('x2')),
  ),
  'user: use cloud': (c) => const UserUsedCloud('x'),
  'user: delete anyway': (c) => const UserDeletedAnyway('x'),
  'user: discard': (c) => const UserDiscarded('x'),
  'result: header as it is': (c) => BaseArrived(
    headerReadOf(c.base),
    session: c.queue.session.number,
    point: tick(),
  ),
  'result: page-a with the item at revision 2': (c) => BaseArrived(
    PageRead(
      page: page('page-a', sortIndex: 0),
      elements: [element('e1', revision: 2), element('e2')],
      lineupGroups: const [],
    ),
    session: c.queue.session.number,
    point: tick(),
  ),
  'result: page-a with the item as this device wrote it at 2': (c) =>
      BaseArrived(
        pageReadOf(withOp(initialRows(), movePatch('m')), 'page-a'),
        session: c.queue.session.number,
        point: tick(),
      ),
  'result: page-a from a session that ended': (c) => BaseArrived(
    pageReadOf(initialRows(), 'page-a'),
    session: c.queue.session.number - 1,
    point: tick(),
  ),
  'result: page-b gone': (c) => BaseArrived(
    const PageGone('page-b'),
    session: c.queue.session.number,
    point: tick(),
  ),
  'result: strategy gone': (c) => BaseArrived(
    const StrategyGone(),
    session: c.queue.session.number,
    point: tick(),
  ),
  'result: page list the store would not keep': (c) =>
      c.readRefused(null, 'ResultWithoutLife(page-a)'),
  'user: discard what was set aside': (c) => const UserDiscardedReplaced(),
  'result: page-a of another life': (c) => BaseArrived(
    PageRead(
      page: LivePage(
        publicId: 'page-a',
        strategyPublicId: strategyId,
        name: 'Page 1',
        sortIndex: 0,
        isAttack: true,
        revision: 1,
        unknownFields: jsonObject({'createdAt': fixtureLife + 86400000}),
      ),
      elements: c.base.elementsOn('page-a').toList(),
      lineupGroups: const [],
    ),
    session: c.queue.session.number,
    point: tick(),
  ),
  'result: page list of an earlier strategy life': (c) => BaseArrived(
    headerReadOf(
      StrategyRowSet(
        strategy: strategyRow(
          createdAt: strategyCreatedAt.subtract(const Duration(days: 1)),
        ),
        pages: c.base.pages,
        settings: c.base.settings,
        elements: const [],
        lineupGroups: const [],
      ),
    ),
    session: c.queue.session.number,
    point: tick(),
  ),
  'result: page list of a later strategy life': (c) => BaseArrived(
    headerReadOf(
      StrategyRowSet(
        strategy: strategyRow(
          createdAt: strategyCreatedAt.add(const Duration(days: 1)),
        ),
        pages: c.base.pages,
        settings: c.base.settings,
        elements: const [],
        lineupGroups: const [],
      ),
    ),
    session: c.queue.session.number,
    point: tick(),
  ),
};

String describe(Client client, String id) {
  final entry = client.queue.entry(id);
  if (entry == null) {
    return switch (client.queue.strategy.setAside) {
      SetAside(:final entries) when entries.any((kept) => kept.id == id) =>
        'set aside',
      _ => 'gone',
    };
  }
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
        if (queue.shown.list != before.queue.shown.list)
          'page list ${queue.shown.list}',
        for (final page in {
          ...queue.shown.pageReads.keys,
          ...before.queue.shown.pageReads.keys,
        })
          if (queue.shown.pageRead(page) != before.queue.shown.pageRead(page))
            '$page ${queue.shown.pageRead(page)}',
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
            ReportSameOrderDiffers(:final page) =>
              'reports two results at one point that differ for '
                  '${page ?? 'the page list'}',
            ReportAccountMismatch() => 'reports another account',
            AnswerAdmitted(:final attempt, :final opId) =>
              'admits attempt $attempt\'s answer'
                  '${opId == null ? '' : ' for $opId'}',
            StrategySetAside(:final count) => 'sets $count aside',
            ReportReplacedWithoutLife(:final attempt) =>
              'reports attempt $attempt replaced without a life',
            PageResultDeferred(:final page) => 'defers $page for the page list',
            SetAsideDiscarded(:final count) => 'discards $count set aside',
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
      'wrote, which never applies to `row_replaced`: that row is another life '
      'of the row, so the op is not delivered whatever its value. Failed: the '
      'user decides.',
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
      '- A field merge that stays on its page names its fields and goes at '
      'its authored revision once no earlier edit of this device on that row '
      'is still unanswered; this device\'s landed work on the row never holds '
      'it, and the server merges it field by field. A merge that names '
      'another page is written whole by the server, so it is gated like a '
      'whole-row write.',
    )
    ..writeln(
      '- Any other op made behind this device\'s queued or landed work on its '
      'row, a nothing-to-do answer included, goes only once that row is '
      'justified at the revision it names, with the content the user saw (or '
      'already holding what the op writes). Otherwise it waits for the '
      'row\'s result, and needs the user when a result of this session shows '
      'the row otherwise, or when a result of its page no longer holds a row '
      'that results showed or this device added. Once a current result shows '
      'its page gone, it names the revision the user saw instead of waiting '
      'for its row; its other holds and the resend window still apply, a '
      'delete goes in its checked form, and the server\'s answer settles it.',
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
      'revision or later, or until a result about the page its op names, at '
      'or after its answer by order and server time, shows that page gone: '
      'that page\'s own page-gone, or a list newer than the page\'s own '
      'result that no longer has it. An item edit that names no page is not '
      'retired this way, as an answer names a revision and not where the row '
      'is. A result about another page never retires work, and while the '
      'strategy itself is gone nothing retires. A delete this device made '
      'stays known as its own until a result shows a later revision of the '
      'row or its page is gone that way. '
      'An undo onto a page that is gone names the revision the user saw '
      'and waits only for its other holds; the server\'s answer settles it.',
    )
    ..writeln()
    ..writeln('## Which copy of a row a result leaves held')
    ..writeln()
    ..writeln(
      '- `Shown.taken` decides once, for every row a result carries, whether '
      'it replaces the copy held, and names every row the result removes. The '
      'store writes what it decides and nothing else. A row replaces the held '
      'copy unless the held copy is newer: lives compare first when both are '
      'known, revisions otherwise. A row without a revision never replaces '
      'one with a revision. A taken row whose stored copy already has the '
      'same contents is not written again. One removal can cover several '
      'stored rows: a page leaving takes its page row, its settings and every '
      'item on it, damaged ones included.',
    )
    ..writeln(
      '- Every result carries a stamp: the client, the connection, the '
      'snapshot and the server time. Its order is the session, then the '
      'client, then the snapshot. `taken` is never given a result older than '
      'one already taken for the same page or the same list. `resultFit` in '
      '`lib/src/cloud/queue.dart` drops those as `OlderResult` before any row '
      'is compared. A result at the order already taken is the same answer: it '
      'pays what it would have paid and changes no content, and one whose '
      'content differs is reported (`ReportSameOrderDiffers`) and changes '
      'nothing. A page\'s taken order is about the results seen for that '
      'page: a list that removes the page leaves it as it was, and only a new '
      'session drops it.',
    )
    ..writeln(
      '- Which pages exist is decided by the newest claim about that page, '
      'whatever kind of result made it. A list claims, for every page, that it '
      'is live, trashed or absent; a page\'s own result claims live or trashed '
      '(`PageRead`) or gone (`PageGone`). The newer claim by order wins, and a '
      'claim older than the other kind\'s claim for that page changes nothing '
      'about existence. So a list removes a page it does not list only when '
      'that page\'s own result is older than the list or there is none, does '
      'not bring back a page whose own newer result says it is gone, and sets '
      'a listed page live or trashed only over an older own result. A '
      '`PageGone` older than the list taken is dropped as `OlderResult`, and '
      'so is a `PageRead` older than a list that does not list the page; a '
      '`PageRead` older than a list that lists the page gives its items and '
      'nothing else. A list and a page result at the same order that disagree '
      'about whether the page exists are reported '
      '(`ReportSameOrderDiffers`) and leave that page as held; the rest of '
      'the list still applies.',
    )
    ..writeln(
      '- Each kind of row has its sources. The list carries the strategy row '
      'and the settings rows: a list writes the settings of every page it '
      'lists, under the version rule above, so a settings row at a lower '
      'revision than the one held is kept out. Page rows come from both '
      'kinds: a page\'s own result newer than the list writes that page\'s '
      'row whole, its place in the list included, so until the next list two '
      'pages can show the same place; that list sets every page row it '
      'decides. A page\'s own result owns '
      'that page\'s items, ordered by that page\'s taken order. A list that '
      'adopts a later strategy life starts from nothing: no taken or refused '
      'order of the old life is kept.',
    )
    ..writeln(
      '- A mark advances only with the content applied for its subject; a '
      'refusal, a dropped result, or a result about another subject moves '
      'none. A read refusal keeps its own order for its subject: it is '
      'dropped when it is not newer than the content taken there or is older '
      'than the last refusal taken, and the first result at a refused point '
      'is taken. A read refusal replaces only an order owed, and only with '
      'its own order; any other debt stays as it was.',
    )
    ..writeln()
    ..writeln('## When the stored base disagrees with the queue')
    ..writeln()
    ..writeln(
      'The queue\'s record (`Shown`) and the stored rows must agree. When a '
      'strategy\'s queue loads: its strategy, page and settings rows, and '
      'which items are stored on which page. When a page loads, before any '
      'of its rows is used: each item\'s page and version, and in checked '
      'builds its contents against a digest this run computed. Two rows agree '
      'when their name, page and version match, whether or not this build can '
      'read their contents. A damaged row (one that does not parse as a '
      'placed row) never agrees. Rows of a kind this build does not know are '
      'left out. After a restart two differences pass the page check: '
      'contents changed at the same version, found only when a result for '
      'that row arrives (and refused there in checked builds), and a damaged '
      'payload in a row that still parses as placed, counted as damaged on its '
      'page. No decision is ever made from unchecked rows. A strategy whose '
      'queue cannot be read makes no decisions at all: no result is taken and '
      'no work is committed, and its rows are shown unchecked and marked '
      'held, as before this check. The only writes made in that state are '
      'the ones the user explicitly chooses: discarding the unreadable queue, '
      'which removes the base rows and owes the page list, and removing the '
      'strategy.',
    )
    ..writeln()
    ..writeln(
      'The stored results (`read/header` and `read/page/…`) are the one part '
      'of the queue that does not hold the strategy when this build cannot '
      'read it, whether a newer build wrote it in a shape this one does not '
      'know or the row is damaged. When any of them cannot be read, and '
      'nothing else of the queue is unreadable, the load drops all of them, '
      'since they mean something only together, and rebuilds `Shown` from the '
      'stored base rows: the strategy, page and settings rows, every stored '
      'item on the page it is stored on, the contents of each live page that '
      'holds items, and the highest version of each row at the version stored. '
      'Nothing is read this session: no debts, no results taken, no marks. '
      'The rows-agree check then runs against what was rebuilt and passes '
      'unless a row is damaged or an item is stored on two pages or on a page '
      'with no page row, which refuses the strategy as before and writes '
      'nothing. Otherwise one commit at load removes every stored results row '
      'and writes the rebuilt ones in their place, leaving the base rows, '
      'entries, attempts, landed work and strategy facts byte for byte as they '
      'were, and the sender reports it once. What the dropped rows held that '
      'the rebuild does not: debts, which a later session pays (every result '
      'after the restart is one, and a read labelled with the ended session '
      'is refused); versions of rows no longer stored, which only matter '
      'against a page list or page result read this session, and are raised '
      'again by it; and contents for a page read with no items, which the '
      'sender reads again, a copy of that page being refused until it has. '
      'Work a dropped debt held waits no longer for it: it was written in an '
      'earlier session, so it goes out checked, at its revision and naming '
      'the strategy and row lives it was written over, and the server refuses '
      'it if the row or the strategy was replaced, which owes the read again. '
      'Work that needs a result read this session (a held page delete, a '
      'whole-row edit behind our own work) waits for it as after any restart, '
      'and landed work stays drawn until a result shows it. A queue entry, attempt, '
      'landed work or facts row this build cannot read still holds the '
      'strategy, and so do stored results beside it. '
      '`test/cloud_results_dropped_test.dart` covers each of these.',
    )
    ..writeln()
    ..writeln(
      'A disagreement refuses the strategy: nothing is written, no result is '
      'taken, the reader does not show it, and the sender neither reads nor '
      'sends for it and reports the reason once. Queued work stays on disk as '
      'it was. How a refused strategy gets its copy back is decided before the '
      'store is switched on for users (#819).',
    )
    ..writeln()
    ..writeln(
      'Nothing about the refusal is stored. A disagreement found in this '
      'session refuses that strategy from the load that found it until the '
      'store closes, or until the strategy\'s stored rows are removed from '
      'this device or written afresh (the strategy removed, its rows found '
      'gone, its unreadable queue discarded, or the strategy added to the '
      'store again); it is never written to disk and is consulted only to '
      'refuse that strategy\'s open. After a restart the open passes the '
      'queue-load check when the fault is on a page. A fault the page check '
      'finds refuses the strategy again as soon as that page loads, whether '
      'a reader, a result or the summary loads it first; the two differences '
      'that pass the page check after a restart (above) are found only as '
      'said there, or not at all. Each refusal the store makes '
      'carries a serial that only grows for the life of the store instance '
      'and is never stored; the sender reports each serial once, and a sender '
      'that starts later asks the store for the refusals standing then. A '
      'queue load can refresh the sync tally shown in memory before a page '
      'check refuses the strategy, so the summary shown can change although '
      'its saved bytes do not.',
    )
    ..writeln()
    ..writeln(
      '- When a page result leaves out an item the device held there, the '
      'item is marked with that result\'s read order and the version last '
      'held. A later-arriving result whose read started before that order, '
      'carrying the item at that version or older, does not bring it back; a '
      'newer version always does. Marks are kept in memory and end with the '
      'session. `test/cloud_row_decision_test.dart` covers both ("a page '
      'result read before another page removed an item stays out when it '
      'carries the version last held, and is taken when it carries a newer '
      'one").',
    )
    ..writeln(
      '- One case is taken although it may be stale. The device holds an '
      'item on page A. On the server it moves to page B, and a read of B '
      'starts. While that read is in flight, the item moves back to A, is '
      'deleted, and is purged by the server. A read of A that started after '
      'the read of B arrives first and leaves the item out. Then the read of '
      'B arrives carrying the item at a version newer than the one last '
      'held, so nothing shows it is stale, and the item is shown on B. A '
      'purged row has been deleted for a long time, so all of this has to '
      'happen while one read is in flight. The next read of B removes it. A '
      'read of the same page that started before the removal is dropped '
      'whole as older. The same case arises without the move back when the '
      'device never saw the move to B: the read of A leaves the item out, and '
      'an older read of B arrives after it carrying the item at a version '
      'newer than the device held. It is taken for the same reason and '
      'corrected the same way.',
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
      'page delete can land after a teammate changed the page '
      '([#670](https://github.com/SunkenInTime/icarus/issues/670)). Until the '
      'server checks the page itself, one rule decides a page delete, with no '
      'partial cases. It is decided only when the device holds a page list '
      'and a result of that page, both taken in the current session and both '
      'current for that page. Every answer of this device, whatever it says, '
      'leaves a mark: on every page its op touches (both ends of a move), on '
      'the page list when it changes the list, on every page when it '
      'renumbers pages, and on the row it wrote. A result meets a mark when '
      'it is at or after the answer in order and, if the answer carried a '
      'server time, at or after that time; it also meets it when it shows the '
      'row the answer wrote at the answer\'s revision or later. Marks of '
      'several answers on one subject combine: the latest order and time, '
      'and the newest revision written of each row, so a result showing '
      'every one of those rows at that revision or later meets them all, '
      'and one answer that wrote no row leaves only order and time. A page\'s '
      'result is current when it meets the marks on that page, on every page, '
      'and on every row it shows now, wherever the row was when the answer '
      'came; the page list is current for a page when it meets the list\'s '
      'marks and that page\'s. Marks live in memory: a session opening keeps '
      'them, a restart drops them. Until then it waits, and `resultsNeeded` '
      'asks for '
      'whichever of the two is missing. Then: if the page list says the page '
      'is gone, the delete goes and the server answers; the page\'s own result '
      'is not needed then, since it cannot change the outcome. Otherwise the '
      'page '
      '(its name, its settings, and the rows on it by id and content, '
      'leaving out a row a result shows on another page) is compared with '
      'what the user saw: equal means the delete goes, anything else means '
      'the user is asked. Both results arrive after every answered op of '
      'this device\'s that touches the page, so they already include its '
      'landed work. A delete with nothing ahead of it on a page already read '
      'this session goes at once; a delete queued behind this device\'s own '
      'work on that page waits for the page list and the page to come round '
      'once more after the last answer. That wait is deliberate and goes away '
      'with #670. A current page list newer than the page\'s own result that '
      'leaves the page out settles it as gone. Otherwise a page list and a '
      'page result that disagree about whether the page exists are no '
      'verdict: the delete waits and asks for both. For a page delete the hold\'s verdict that the '
      'page is gone comes before the revision check, and a page delete queued '
      'behind other entries asks for nothing until it reaches the head. All '
      'of this lives in '
      '`lib/src/cloud/held_page_delete.dart` and comes out in one piece when '
      '#670 lands.',
    );
  for (final row in rows) {
    final client = row.build();
    out
      ..writeln()
      ..writeln('## ${row.label}')
      ..writeln()
      ..writeln(
        'Starts as: ${describe(client, row.subject)}'
        '${isDebt(client.queue.shown.list) ? '; page list ${client.queue.shown.list}' : ''}.',
      )
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
      if (client.queue.entry(row.subject) case final entry?) {
        kinds.add(kindOf(entry, views[row.subject]));
      }
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
    expect(file.readAsStringSync().replaceAll('\r\n', '\n'), rendered);
  });
}
