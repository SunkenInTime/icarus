import 'dart:io';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_support.dart';
import 'support.dart';

const tablePath = 'doc/cloud_transitions.md';

final subjectPatch = movePatch('x');
final subjectDelete = pageDelete('x', 'page-a');
final seenPageA = seenOf(
  'Page 1',
  content: {const SeenSettings(): 1, const SeenElement('e1'): 5},
);

final retired = RetiredOp(
  opId: 'x',
  clientId: clientId,
  stored: const {'type': 'lineup.link.add'},
);

AnswerUnknown unknown(int failures) => AnswerUnknown(
  failures: failures,
  retryAt: const RetryNow(),
  cause: const TransportCut(TransportFailure.network),
);

final rows = <String, QueueEntry>{
  'never sent, free': pending(subjectPatch, neverSentFree),
  'never sent, paused: edit access removed': pending(
    subjectPatch,
    const Unsent(NeverSent(), Paused(PauseReason.editAccessRemoved)),
  ),
  'never sent, paused: upgrade required': pending(
    subjectPatch,
    const Unsent(NeverSent(), Paused(PauseReason.upgradeRequired)),
  ),
  'answer unknown, free': pending(
    subjectPatch,
    Unsent(unknown(2), const Free()),
  ),
  'answer unknown, paused: retries exhausted': pending(
    subjectPatch,
    Unsent(unknown(8), const Paused(PauseReason.retriesExhausted)),
  ),
  'never sent, needs user: oversized': pending(
    subjectPatch,
    const Unsent(NeverSent(), NeedsUser(Oversized())),
  ),
  'never sent, needs user: no longer fits': pending(
    subjectPatch,
    const Unsent(NeverSent(), NeedsUser(NoLongerFits(5))),
  ),
  'never sent, needs user: incomplete page copy': pending(
    subjectPatch,
    const Unsent(NeverSent(), NeedsUser(IncompletePageCopy('page-a'))),
  ),
  'answer unknown, needs user: strategy deleted': pending(
    subjectPatch,
    Unsent(unknown(1), const NeedsUser(StrategyDeleted())),
  ),
  'page delete, never sent, free, not yet checked': pending(
    subjectDelete,
    neverSentFree,
    check: CheckAgainst(seenPageA),
  ),
  'page delete, never sent, needs user: held, page changed': pending(
    subjectDelete,
    const Unsent(
      NeverSent(),
      NeedsUser(HeldPageDelete(HeldDeleteCause.pageChanged)),
    ),
    check: CheckAgainst(seenPageA),
  ),
  'claimed, was never sent': pending(subjectPatch, const Claimed(NeverSent())),
  'claimed, answer was unknown': pending(subjectPatch, Claimed(unknown(2))),
  'accepted at 5': pending(subjectPatch, const Accepted(5)),
  'refused: revision_mismatch': pending(
    subjectPatch,
    ServerRefused(
      RejectedByServer(RejectionReason.revisionMismatch, snapshotAt(5)),
    ),
  ),
  'failed on the server: INVALID_PAYLOAD': pending(
    subjectPatch,
    const ServerRefused(
      FailedOnServer(KnownFailure(FailureCode.invalidPayload), 'bad payload'),
    ),
  ),
  'retired format': retired,
};

ServerSnapshot snapshotAt(int revision) => ServerSnapshot(
  target: SnapshotTarget.element,
  revision: revision,
  value: agentPayload('e1', const {}).toJson(),
);

PageRead pageRead({List<ElementRow>? elements}) => PageRead(
  page: page('page-a', sortIndex: 0),
  settings: settings('page-a'),
  elements: elements ?? [element('e1', revision: 5)],
  lineupGroups: const [],
);

final events = <String, QueueEvent>{
  'user edits another item': UserEdited(
    PlainEdit(movePatch('y', elementId: 'e2')),
    clientId: clientId,
  ),
  'batch claimed': BatchClaimed(['x']),
  'claim released before transport': ClaimReleased(['x']),
  'applied at 5': const OpAnswered(AppliedAnswer('x', revision: 5)),
  'noop at 5, applied when first received': const OpAnswered(
    NoopAnswer('x', revision: 5, replay: NoopReplay.appliedWhenFirstReceived),
  ),
  'noop at 5, not applied': const OpAnswered(
    NoopAnswer('x', revision: 5, replay: NoopReplay.notApplied),
  ),
  'noop without a revision': const OpAnswered(NoopWithoutRevision('x')),
  for (final reason in RejectionReason.values)
    'rejected: ${reason.wireName}': OpAnswered(
      RejectedAnswer('x', reason, snapshotAt(6)),
    ),
  'rejected: revision_mismatch, no server copy': const OpAnswered(
    RejectedAnswer('x', RejectionReason.revisionMismatch, NoServerCopy()),
  ),
  'failed: PAGE_DELETED': const OpAnswered(
    FailedAnswer('x', KnownFailure(FailureCode.pageDeleted), 'page deleted'),
  ),
  'failed: INTERNAL_ERROR': const OpAnswered(
    FailedAnswer('x', OtherFailure('INTERNAL_ERROR'), 'unexpected'),
  ),
  'transport failed: network': TransportFailed(
    ['x'],
    TransportFailure.network,
    at: now,
  ),
  for (final refusal in BatchRefusal.values)
    'batch refused: ${refusal.name}': BatchRefused(['x'], refusal),
  'app restarted': const AppRestarted(),
  'connection lost': const ConnectionLost(),
  'connection returned': const ConnectionReturned(),
  'account changed': const AccountChanged(),
  'user: retry': const UserRetried('x'),
  'user: keep mine': UserKeptMine('x', movePatch('x2', expected: 6)),
  'user: use cloud': const UserUsedCloud('x'),
  'user: delete anyway': const UserDeletedAnyway('x'),
  'user: discard': const UserDiscarded('x'),
  'work no longer fits, server at 5': const WorkNoLongerFits(
    'x',
    serverRevision: 5,
  ),
  'base: page read shows the item at 5': BaseArrived(pageRead()),
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
};

String describeState(PendingState state) => switch (state) {
  Unsent(:final delivery, :final go) =>
    '${describeDelivery(delivery)}, ${describeGo(go)}',
  Claimed(:final before) => 'claimed, was ${describeDelivery(before)}',
  Accepted(:final revision) => 'accepted at $revision',
  ServerRefused(refusal: RejectedByServer(:final reason, :final current)) =>
    'refused: ${reason.wireName}, ${describeCopy(current)}',
  ServerRefused(refusal: FailedOnServer(:final code)) =>
    'failed on the server: $code',
};

String describeCopy(ServerCopy copy) => switch (copy) {
  NoServerCopy() => 'no server copy',
  ServerSnapshot(:final revision) => 'server copy at $revision',
};

String describeDelivery(Unclaimed delivery) => switch (delivery) {
  NeverSent() => 'never sent',
  AnswerUnknown(:final failures, :final retryAt, :final cause) =>
    'answer unknown (${switch (cause) {
      TransportCut(:final failure) => failure.name,
      AppClosedWhileSending() => 'app closed while sending',
    }}, $failures failures${switch (retryAt) {
      RetryNow() => '',
      RetryAfter(:final at) => ', retry in ${at.difference(now).inMilliseconds} ms',
    }})',
};

String describeGo(Go go) => switch (go) {
  Free() => 'free',
  Paused(:final reason) => 'paused: ${reason.name}',
  NeedsUser(:final reason) =>
    'needs user: ${switch (reason) {
      Oversized() => 'oversized',
      NoLongerFits(:final serverRevision) => 'no longer fits (server at $serverRevision)',
      IncompletePageCopy(:final pagePublicId) => 'incomplete copy of $pagePublicId',
      HeldPageDelete(:final cause) => 'held page delete (${cause.name})',
      StrategyDeleted() => 'strategy deleted',
    }}',
};

String describeEntry(QueueEntry entry) => switch (entry) {
  PendingOp(:final opId, :final state, :final check) =>
    '${opId == 'x' ? '' : '$opId: '}${describeState(state)}'
        '${check is NoCheck && entry.op is PageDeleteOp ? ', unchecked delete' : ''}',
  RetiredOp() => 'retired format',
};

String describeEffect(QueueEffect effect) => switch (effect) {
  OpRemoved(:final opId, :final cause) =>
    'removes $opId (${switch (cause) {
      SeenInBase() => 'seen in base',
      NothingToWaitFor() => 'nothing to wait for',
      LandedBeforeStrategyDeleted() => 'landed before the strategy was deleted',
      RemovedByUser(:final action, :final landing) => '${action.name}, ${landing.name}',
    }})',
  OpRebased(:final opId, :final revision) => 'rebases $opId onto $revision',
  ReportUnauthenticated() => 'reports unauthenticated',
  HoldSendingForUpgrade() => 'holds sending until upgrade',
};

String outcome(QueueEntry subject, Step result) {
  switch (result) {
    case NotApplicable():
      return '';
    case Stepped(:final queue, :final effects):
      final parts = <String>[];
      final after = queue.entry('x');
      if (after == null) {
        parts.add('removed');
      } else if (after != subject) {
        parts.add(describeEntry(after));
      } else {
        parts.add('unchanged');
      }
      if (queue.entry('x2') case final replacement?) {
        parts.add('replaced by ${describeEntry(replacement)}');
      }
      if (queue.deletesCheckedThisSession.contains('x')) {
        parts.add('checked this session');
      }
      parts.addAll(effects.map(describeEffect));
      return parts.join('; ');
  }
}

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
      'Each section starts from a queue holding one op `x` in that state '
      '(an element patch, or a page delete where named) and applies one '
      'event. Events that do not apply in that state are listed after the '
      'table; the queue is left as it was.',
    );
  for (final MapEntry(key: label, value: subject) in rows.entries) {
    out
      ..writeln()
      ..writeln('## $label')
      ..writeln()
      ..writeln('| Event | Result |')
      ..writeln('| --- | --- |');
    final ignored = <String>[];
    for (final MapEntry(key: name, value: event) in events.entries) {
      final result = outcome(
        subject,
        transition(queueOf([subject]), event, now: now),
      );
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
    for (final subject in rows.values) {
      for (final event in events.values) {
        expect(transition(queueOf([subject]), event, now: now), isA<Step>());
      }
    }
  });

  test('the table in $tablePath is the one the code gives', () {
    final rendered = renderTable();
    final file = File(tablePath);
    if (Platform.environment['UPDATE_TRANSITIONS'] == '1') {
      file.writeAsStringSync(rendered);
    }
    expect(file.readAsStringSync(), rendered);
  });

  test('every state the types allow has a row', () {
    final kinds = {
      for (final subject in rows.values)
        switch (subject) {
          PendingOp(:final state) => switch (state) {
            Unsent(:final delivery, :final go) =>
              '${delivery.runtimeType}/${switch (go) {
                Free() => 'Free',
                Paused() => 'Paused',
                NeedsUser(:final reason) => reason.runtimeType.toString(),
              }}',
            _ => state.runtimeType.toString(),
          },
          RetiredOp() => 'RetiredOp',
        },
    };
    expect(
      kinds,
      containsAll([
        'NeverSent/Free',
        'NeverSent/Paused',
        'AnswerUnknown/Free',
        'AnswerUnknown/Paused',
        'NeverSent/Oversized',
        'NeverSent/NoLongerFits',
        'NeverSent/IncompletePageCopy',
        'NeverSent/HeldPageDelete',
        'AnswerUnknown/StrategyDeleted',
        'Claimed',
        'Accepted',
        'ServerRefused',
        'RetiredOp',
      ]),
    );
  });
}
