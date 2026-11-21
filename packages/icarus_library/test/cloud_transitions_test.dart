import 'dart:io';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_support.dart';
import 'support.dart';

const tablePath = 'doc/cloud_transitions.md';

enum EntryKind {
  neverSentFree,
  neverSentOversized,
  neverSentNoLongerFits,
  neverSentIncompletePageCopy,
  neverSentOnDeletedPage,
  answerUnknownFree,
  answerUnknownRetriesExhausted,
  answerUnknownServerForgot,
  answerUnknownNeedsUser,
  deleteAwaitingCheck,
  deleteHeldForUser,
  claimedFromNeverSent,
  claimedFromAnswerUnknown,
  accepted,
  rejectedByServer,
  failedOnServer,
  retired,
  unreadable,
}

EntryKind kindOf(QueueEntry entry) => switch (entry) {
  RetiredOp() => EntryKind.retired,
  UnreadableEntry() => EntryKind.unreadable,
  PendingOp(work: CheckedDelete(verdict: AwaitingCheck())) =>
    EntryKind.deleteAwaitingCheck,
  PendingOp(work: CheckedDelete(verdict: HeldForUser())) =>
    EntryKind.deleteHeldForUser,
  PendingOp(work: OpWork(), :final state) => switch (state) {
    Unsent(delivery: NeverSent(), go: Free()) => EntryKind.neverSentFree,
    Unsent(delivery: NeverSent(), go: NeedsUser(:final reason)) =>
      switch (reason) {
        Oversized() => EntryKind.neverSentOversized,
        NoLongerFits() => EntryKind.neverSentNoLongerFits,
        IncompletePageCopy() => EntryKind.neverSentIncompletePageCopy,
        OnDeletedPage() => EntryKind.neverSentOnDeletedPage,
      },
    Unsent(delivery: AnswerUnknown(retry: RetriesExhausted()), go: Free()) =>
      EntryKind.answerUnknownRetriesExhausted,
    Unsent(
      delivery: AnswerUnknown(retry: RetryNow() || RetryAfter()),
      go: Free(),
    ) =>
      EntryKind.answerUnknownFree,
    Unsent(delivery: AnswerUnknown(retry: ServerForgotAnswer()), go: Free()) =>
      EntryKind.answerUnknownServerForgot,
    Unsent(delivery: AnswerUnknown(), go: NeedsUser()) =>
      EntryKind.answerUnknownNeedsUser,
    Claimed(before: NeverSent()) => EntryKind.claimedFromNeverSent,
    Claimed(before: AnswerUnknown()) => EntryKind.claimedFromAnswerUnknown,
    Accepted() => EntryKind.accepted,
    ServerRefused(refusal: RejectedByServer()) => EntryKind.rejectedByServer,
    ServerRefused(refusal: FailedOnServer()) => EntryKind.failedOnServer,
  },
};

final seenPageA = seenOf(
  'Page 1',
  content: {const SeenSettings(): 1, const SeenElement('e1'): 5},
);

ServerSnapshot snapshotAt(int revision) => ServerSnapshot(
  target: SnapshotTarget.element,
  revision: revision,
  value: agentPayload('e1', const {}).toJson(),
);

PendingOp subject(PendingState state, {Work? work, StrategyOp? op}) =>
    pending(op ?? movePatch('x'), state, work: work);

final deleteX = pageDelete('x', 'page-a');

final class Row {
  Row(this.label, this.entries, {this.standing = Standing.good});

  final String label;
  final List<QueueEntry> entries;
  final Standing standing;
}

final rows = <Row>[
  Row('never sent, free', [subject(neverSentFree)]),
  Row('never sent add, free', [
    subject(neverSentFree, op: elementAdd('x', elementId: 'e1')),
  ]),
  Row('never sent, needs user: oversized', [
    subject(const Unsent(NeverSent(), NeedsUser(Oversized()))),
  ]),
  Row('never sent, needs user: no longer fits', [
    subject(const Unsent(NeverSent(), NeedsUser(NoLongerFits(5)))),
  ]),
  Row('never sent, needs user: incomplete page copy (import only)', [
    subject(
      const Unsent(
        NeverSent(),
        NeedsUser(IncompletePageCopy.imported('page-a')),
      ),
    ),
  ]),
  Row('never sent, needs user: on a deleted page', [
    subject(const Unsent(NeverSent(), NeedsUser(OnDeletedPage('page-a')))),
  ]),
  Row('answer unknown, free', [subject(Unsent(unknown(2), const Free()))]),
  Row('answer unknown, retries exhausted', [
    subject(Unsent(unknown(8, retry: const RetriesExhausted()), const Free())),
  ]),
  Row('answer unknown, the server forgot the answer', [
    subject(
      Unsent(unknown(1, retry: const ServerForgotAnswer()), const Free()),
    ),
  ]),
  Row('answer unknown, needs user: no longer fits', [
    subject(Unsent(unknown(1), const NeedsUser(NoLongerFits(5)))),
  ]),
  Row('page delete awaiting its check', [
    subject(
      neverSentFree,
      op: deleteX,
      work: CheckedDelete(deleteX, seenPageA, const AwaitingCheck()),
    ),
  ]),
  Row('page delete held for the user: page changed', [
    subject(
      neverSentFree,
      op: deleteX,
      work: CheckedDelete(
        deleteX,
        seenPageA,
        const HeldForUser(HeldDeleteCause.pageChanged),
      ),
    ),
  ]),
  Row('claimed by a1, was never sent', [
    subject(Claimed(attempt('a1'), const NeverSent())),
  ]),
  Row('claimed by a1, answer was unknown', [
    subject(Claimed(attempt('a1'), unknown(2))),
  ]),
  Row('accepted at 5', [subject(const Accepted(5))]),
  Row('refused: revision_mismatch, server at 6', [
    subject(
      ServerRefused(
        RejectedByServer(RejectionReason.revisionMismatch, snapshotAt(6)),
      ),
    ),
  ]),
  Row('refused, with a later edit of the same item stacked on it', [
    subject(
      ServerRefused(
        RejectedByServer(RejectionReason.revisionMismatch, snapshotAt(6)),
      ),
    ),
    pending(
      movePatch('y', expected: 2, x: 20),
      neverSentFree,
      place: 1,
      against: const StackedOn('x', 2),
    ),
  ]),
  Row('failed on the server: PAGE_DELETED', [
    subject(
      const ServerRefused(
        FailedOnServer(KnownFailure(FailureCode.pageDeleted), 'page deleted'),
      ),
    ),
  ]),
  Row('retired format, may have landed', [
    RetiredOp(
      place: 0,
      opId: 'x',
      clientId: clientId,
      landing: Landing.mayHaveLanded,
      stored: const {'type': 'lineup.link.add'},
    ),
  ]),
  Row('unreadable entry', [
    const UnreadableEntry(place: 0, text: '{"version":99}', problem: 'newer'),
  ]),
  Row(
    'never sent, free, strategy deleted on the server',
    [subject(neverSentFree)],
    standing: Standing.deletedOnServer,
  ),
  Row('never sent, free, edit access lost', [
    subject(neverSentFree),
  ], standing: Standing.editAccessLost),
  Row('never sent, free, upgrade required', [
    subject(neverSentFree),
  ], standing: Standing.upgradeRequired),
];

PageRead pageRead({List<ElementRow>? elements}) => PageRead(
  page: page('page-a', sortIndex: 0),
  settings: settings('page-a'),
  elements: elements ?? [element('e1', revision: 5)],
  lineupGroups: const [],
);

final events = <String, QueueEvent>{
  'user edits another item': userEdits(movePatch('z', elementId: 'e2')),
  'user edits the same item': userEdits(movePatch('w', expected: 2, x: 30)),
  'user deletes the same item': userEdits(elementDelete('w', expected: 2)),
  'claimed as a2': BatchClaimed(attempt('a2'), ['x']),
  'claimed as a2 under another client id': BatchClaimed(
    attempt('a2', client: 'client-2'),
    ['x'],
  ),
  'a1 released before transport': const ClaimReleased('a1'),
  'applied at 5': answered(const AppliedAnswer('x', revision: 5)),
  'applied at 5, base already shows 5': answered(
    const AppliedAnswer('x', revision: 5),
    base: const BaseHolds(5),
  ),
  'noop at 5, applied when first received': answered(
    const NoopAnswer(
      'x',
      revision: 5,
      replay: NoopReplay.appliedWhenFirstReceived,
    ),
  ),
  'noop at 5, not applied': answered(
    const NoopAnswer('x', revision: 5, replay: NoopReplay.notApplied),
  ),
  'noop without a revision': answered(const NoopWithoutRevision('x')),
  for (final reason in RejectionReason.values)
    'rejected: ${reason.wireName}': answered(
      RejectedAnswer('x', reason, snapshotAt(6)),
    ),
  'rejected: revision_mismatch, no server copy': answered(
    const RejectedAnswer('x', RejectionReason.revisionMismatch, NoServerCopy()),
  ),
  'failed: PAGE_DELETED': answered(
    const FailedAnswer('x', KnownFailure(FailureCode.pageDeleted), 'deleted'),
  ),
  'failed: INTERNAL_ERROR': answered(
    const FailedAnswer('x', OtherFailure('INTERNAL_ERROR'), 'unexpected'),
  ),
  'answer from another client id': answered(
    const AppliedAnswer('x', revision: 5),
    by: attempt('a9', client: 'client-2'),
  ),
  'a1 transport failed': TransportFailed(
    'a1',
    TransportFailure.network,
    at: now,
  ),
  for (final refusal in BatchRefusal.values)
    'a1 refused whole: ${refusal.name}': BatchRefused('a1', refusal),
  'app restarted': const AppRestarted(),
  'connection lost': const ConnectionLost(),
  'connection returned': const ConnectionReturned(),
  'account changed': const AccountChanged(),
  'edit access confirmed': const EditAccessConfirmed(),
  'user: retry': const UserRetried('x'),
  'user: keep mine, same item': UserKeptMine('x', movePatch('x2', expected: 6)),
  'user: keep mine, another item': UserKeptMine(
    'x',
    movePatch('x2', elementId: 'e2'),
  ),
  'user: use cloud': const UserUsedCloud('x'),
  'user: delete anyway': const UserDeletedAnyway('x'),
  'user: discard': const UserDiscarded('x'),
  'page-a restored': PageRestored('page-a', const {'x': 'x3'}),
  'work no longer fits, server at 5': const WorkNoLongerFits(
    'x',
    serverRevision: 5,
  ),
  'base: page read shows the item at 5': BaseArrived(pageRead()),
  'base: page read shows the item at 6': BaseArrived(
    pageRead(elements: [element('e1', revision: 6)]),
  ),
  'base: page read where a teammate added an item': BaseArrived(
    pageRead(elements: [element('e1', revision: 5), element('e7')]),
  ),
  'base: strategy read at revision 5': BaseArrived(
    HeaderRead(
      strategy: strategyRow(revision: 5),
      pages: [page('page-a', sortIndex: 0)],
      settings: [settings('page-a')],
    ),
  ),
  'base: page gone': const BaseArrived(PageGone('page-a')),
  'base: strategy gone': const BaseArrived(StrategyGone()),
  'a month and a day later, connection returned': const ConnectionReturned(),
};

final later = now.add(serverRemembersAnswersFor + const Duration(days: 1));

DateTime timeFor(String event) => event.startsWith('a month') ? later : now;

String describeState(PendingState state) => switch (state) {
  Unsent(:final delivery, :final go) =>
    '${describeDelivery(delivery)}, ${describeGo(go)}',
  Claimed(:final attempt, :final before) =>
    'claimed by ${attempt.id}, was ${describeDelivery(before)}',
  Accepted(:final revision) => 'accepted at $revision',
  ServerRefused(refusal: RejectedByServer(:final reason, :final current)) =>
    'refused: ${reason.wireName}, ${switch (current) {
      NoServerCopy() => 'no server copy',
      ServerSnapshot(:final revision) => 'server at $revision',
    }}',
  ServerRefused(refusal: FailedOnServer(:final code)) => 'failed: $code',
};

String describeDelivery(Unclaimed delivery) => switch (delivery) {
  NeverSent() => 'never sent',
  AnswerUnknown(:final clientId, :final failures, :final retry, :final cause) =>
    'answer unknown (${switch (cause) {
      TransportCut(:final failure) => failure.name,
      AppClosedWhileSending() => 'app closed while sending',
    }}, $failures failures, ${switch (retry) {
      RetryNow() => 'retry now',
      RetryAfter(:final at) => 'retry in ${at.difference(now).inMilliseconds} ms',
      RetriesExhausted() => 'retries exhausted',
      ServerForgotAnswer() => 'the server forgot its answer',
    }}${clientId == 'client-1' ? '' : ', as $clientId'})',
};

String describeGo(Go go) => switch (go) {
  Free() => 'free',
  NeedsUser(:final reason) =>
    'needs user: ${switch (reason) {
      Oversized() => 'oversized',
      NoLongerFits(:final serverRevision) => 'no longer fits (server at $serverRevision)',
      IncompletePageCopy(:final pagePublicId) => 'incomplete copy of $pagePublicId',
      OnDeletedPage(:final pagePublicId) => 'on deleted $pagePublicId',
    }}',
};

String describeEntry(QueueEntry entry) => switch (entry) {
  PendingOp(:final work, :final state, :final wait, :final against) => [
    describeState(state),
    switch (work) {
      OpWork(op: PageDeleteOp()) => 'unchecked delete',
      OpWork() => null,
      CheckedDelete(verdict: AwaitingCheck()) => 'delete awaiting its check',
      CheckedDelete(verdict: HeldForUser(:final cause)) =>
        'delete held for the user (${cause.name})',
    },
    switch (wait) {
      NoWait() => null,
      UntilBaseShows(:final revision) => 'waits for the base to show $revision',
    },
    switch (against) {
      StackedOn(:final opId, :final revision) when opId != 'x' =>
        'stacked on $opId at $revision',
      _ => null,
    },
  ].whereType<String>().join(', '),
  RetiredOp() => 'retired format',
  UnreadableEntry() => 'unreadable entry',
};

String describeEffect(QueueEffect effect) => switch (effect) {
  OpRemoved(:final opId, :final cause) =>
    'removes $opId (${switch (cause) {
      SeenInBase() => 'seen in base',
      NothingToWaitFor() => 'nothing to wait for',
      SettledByRemoval() => 'settled: its page or strategy is gone',
      FoldedInto(:final opId) => 'folded into $opId',
      CancelledBy(:final opId) => 'cancelled by $opId',
      RetriedUnder(:final opId) => 'retried as $opId',
      RemovedByUser(:final action, :final landing) => '${action.name}, ${landing.name}',
    }})',
  OpRebased(:final opId, :final revision) => 'moves $opId onto $revision',
  WorkOnDeletedPage(:final pagePublicId, :final opIds) =>
    'tells the user $opIds were on deleted $pagePublicId',
  ReportUnauthenticated() => 'reports unauthenticated',
  HoldSendingForUpgrade() => 'holds sending until upgrade',
};

String outcome(Row row, Step result) {
  switch (result) {
    case NotApplicable():
      return '';
    case Stepped(:final queue, :final effects):
      final before = {for (final entry in row.entries) entry.id: entry};
      final after = {for (final entry in queue.entries) entry.id: entry};
      final parts = <String>[];
      for (final id in {...before.keys, ...after.keys}) {
        final was = before[id];
        final now = after[id];
        if (now == null) {
          parts.add('$id removed');
        } else if (was == null) {
          parts.add('$id added: ${describeEntry(now)}');
        } else if (was != now) {
          parts.add('$id: ${describeEntry(now)}');
        }
      }
      if (queue.standing != row.standing) {
        parts.add('standing: ${queue.standing.name}');
      }
      if (queue.session.deleteChecks.containsKey('x')) {
        parts.add('check passed this session');
      }
      parts.addAll(effects.map(describeEffect));
      return parts.isEmpty ? 'unchanged' : parts.join('; ');
  }
}

Step stepRow(Row row, String name, QueueEvent event) => transition(
  queueOf(row.entries, standing: row.standing),
  event,
  now: timeFor(name),
);

String renderTable() {
  final out = StringBuffer()
    ..writeln('# Cloud pending op transitions')
    ..writeln()
    ..writeln(
      'Generated by `test/cloud_transitions_test.dart` from `transition` in '
      '`lib/src/cloud/queue.dart`. Run with `UPDATE_TRANSITIONS=1` to rewrite.',
    )
    ..writeln()
    ..writeln(
      'Each section starts from a queue holding op `x` (an element patch on '
      'page-a unless named) in that state, and applies one event at '
      '${now.toIso8601String()}. Events that do not apply are listed after '
      'the table; the queue is left as it was.',
    );
  for (final row in rows) {
    out
      ..writeln()
      ..writeln('## ${row.label}')
      ..writeln()
      ..writeln('| Event | Result |')
      ..writeln('| --- | --- |');
    final ignored = <String>[];
    for (final MapEntry(key: name, value: event) in events.entries) {
      final result = outcome(row, stepRow(row, name, event));
      if (result.isEmpty) {
        ignored.add(name);
      } else {
        out.writeln('| $name | $result |');
      }
    }
    out
      ..writeln()
      ..writeln('Does not apply: ${ignored.join(', ')}.');
  }
  return out.toString();
}

void main() {
  test('every state answers every event without throwing', () {
    for (final row in rows) {
      for (final MapEntry(key: name, value: event) in events.entries) {
        expect(stepRow(row, name, event), isA<Step>());
      }
    }
  });

  test('every kind of entry and every standing has a row', () {
    expect({
      for (final row in rows)
        for (final entry in row.entries) kindOf(entry),
    }, EntryKind.values.toSet());
    expect({for (final row in rows) row.standing}, Standing.values.toSet());
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
