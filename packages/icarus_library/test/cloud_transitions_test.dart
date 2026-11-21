import 'dart:io';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_support.dart';
import 'support.dart';

const tablePath = 'doc/cloud_transitions.md';

enum Kind {
  neverSentFree,
  heldBehindEntry,
  awaitingBase,
  awaitingPageRead,
  oversized,
  changedUnseen,
  deleteHeld,
  onDeletedPage,
  incompleteCopy,
  claimed,
  answerUnknown,
  retriesExhausted,
  serverForgotAnswer,
  accepted,
  rejected,
  failed,
  retired,
  unreadable,
}

Kind kindOf(QueueEntry entry, EntryView? view) => switch ((entry, view)) {
  (RetiredOp(), _) => Kind.retired,
  (UnreadableEntry(), _) => Kind.unreadable,
  (PendingOp(), null) => throw StateError('a pending op always has a view'),
  (PendingOp(), final EntryView view) => switch ((view.state, view.go)) {
    (Claimed(), _) => Kind.claimed,
    (Accepted(), _) => Kind.accepted,
    (ServerRefused(refusal: RejectedByServer()), _) => Kind.rejected,
    (ServerRefused(refusal: FailedOnServer()), _) => Kind.failed,
    (_, NeedsUser(:final reason)) => switch (reason) {
      Oversized() => Kind.oversized,
      ChangedUnseen() => Kind.changedUnseen,
      ServerForgotAnswer() => Kind.serverForgotAnswer,
      OnDeletedPage() => Kind.onDeletedPage,
      DeleteHeld() => Kind.deleteHeld,
      IncompleteCopy() => Kind.incompleteCopy,
    },
    (AnswerUnknown(backoff: RetriesExhausted()), Free()) =>
      Kind.retriesExhausted,
    (NeverSent() || AnswerUnknown(), Free())
        when view.holds.any((hold) => hold is BehindEntry) =>
      Kind.heldBehindEntry,
    (NeverSent() || AnswerUnknown(), Free())
        when view.holds.any((hold) => hold is AwaitingPageRead) =>
      Kind.awaitingPageRead,
    (NeverSent() || AnswerUnknown(), Free())
        when view.holds.any((hold) => hold is AwaitingBase) =>
      Kind.awaitingBase,
    (AnswerUnknown(), Free()) => Kind.answerUnknown,
    (NeverSent(), Free()) => Kind.neverSentFree,
  },
};

final class Row {
  Row(this.label, this.build, {this.subject = 'x'});

  final String label;
  final Client Function() build;
  final String subject;
}

final later = now.add(serverRemembersAnswersFor + const Duration(days: 1));

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

final rows = <Row>[
  Row('never sent, free', () => Client()..edit(movePatch('x'))),
  Row('held behind an earlier edit of the row', () {
    final client = Client()..edit(movePatch('first'));
    client.claim(['first']);
    return client..edit(movePatch('x', expected: 2, x: 30));
  }),
  Row('waiting for the base to show an accepted earlier edit', () {
    final client = Client()..edit(movePatch('first'));
    final attempt = client.claim(['first']);
    client.edit(elementDelete('x', expected: 2));
    return client
      ..must(OpAnswered(attempt, const AppliedAnswer('first', revision: 2)));
  }),
  Row('page delete waiting for a read of its page this session', () {
    return Client()..edit(pageDelete('x', 'page-b'));
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
  Row('needs user: changed by someone else since the user saw it', () {
    final client = Client()..edit(elementDelete('x'));
    return client..read(withOp(initialRows(), movePatch('t', rotation: 90)));
  }),
  Row('needs user: page delete held, page changed', () {
    final client = Client()..edit(pageDelete('x', 'page-a'));
    return client..read(withOp(initialRows(), movePatch('t', rotation: 90)));
  }),
  Row('needs user: on a page whose delete landed', () {
    final client = Client()..edit(pageDelete('del', 'page-b'));
    client.read(initialRows(), pages: ['page-b']);
    final attempt = client.claim(['del']);
    client.edit(elementAdd('x', pageId: 'page-b'));
    client.must(OpAnswered(attempt, const AppliedAnswer('del', revision: 2)));
    return client..read(withOp(initialRows(), pageDelete('del', 'page-b')));
  }),
  Row('needs user: incomplete page copy (import only)', () {
    final client = Client();
    client.queue = CloudQueue(
      entries: [
        PendingOp(
          place: 0,
          work: ImportedIncompleteCopy(
            pageAdd('x', 'page-c', copyFrom: 'page-a'),
          ),
          scope: const OnPage('page-c'),
          authored: const AuthoredNoRow(),
          policy: SendPolicy.checked,
          answer: const NoAnswer(),
          retriedAfter: 0,
        ),
      ],
      attempts: const {},
      nextAttempt: 1,
      base: client.queue.base,
      strategy: StrategyFacts.fresh,
      session: client.queue.session,
    );
    return client;
  }),
  Row('claimed in attempt 1', () {
    final client = Client()..edit(movePatch('x'));
    client.claim(['x']);
    return client;
  }),
  Row('answer unknown', sentAndLost),
  Row('answer unknown, retries exhausted', () {
    final client = Client()..edit(movePatch('x'));
    for (var i = 0; i < retriesBeforePause; i++) {
      final attempt = client.claim(['x']);
      client.must(TransportFailed(attempt, TransportFailure.network, at: now));
      client.clock = now.add(Duration(minutes: i + 1));
    }
    return client..clock = null;
  }),
  Row('needs user: the server forgot whether it landed', () {
    final client = Client()
      ..edit(
        movePatch(
          'x',
          merge: FieldMerge(fields: ['position'], base: {'position': null}),
        ),
      );
    final attempt = client.claim(['x']);
    client.must(TransportFailed(attempt, TransportFailure.network, at: now));
    client.read(
      withOp(
        withOp(initialRows(), movePatch('m', x: 10)),
        movePatch('t', expected: 2, x: 0),
      ),
    );
    return client..clock = later;
  }),
  Row('accepted at 2', () => answered(const AppliedAnswer('x', revision: 2))),
  Row(
    'refused: revision_mismatch',
    () => answered(
      const RejectedAnswer(
        'x',
        RejectionReason.revisionMismatch,
        NoServerCopy(),
      ),
    ),
  ),
  Row(
    'failed on the server: PAGE_DELETED',
    () => answered(
      const FailedAnswer('x', KnownFailure(FailureCode.pageDeleted), 'deleted'),
    ),
  ),
  Row('retired format', () {
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
      nextAttempt: 1,
      base: client.queue.base,
      strategy: StrategyFacts.fresh,
      session: client.queue.session,
    );
    return client;
  }),
  Row('unreadable entry', () {
    final client = Client();
    client.queue = CloudQueue(
      entries: [const UnreadableEntry(place: 0, text: '{}', problem: 'newer')],
      attempts: const {},
      nextAttempt: 1,
      base: client.queue.base,
      strategy: StrategyFacts.fresh,
      session: client.queue.session,
    );
    return client;
  }, subject: 'unreadable/0'),
  Row('never sent, strategy deleted on the server', () {
    return Client()
      ..edit(movePatch('x'))
      ..must(const BaseArrived(StrategyGone()));
  }),
  Row('never sent, edit access lost', () {
    final client = Client()
      ..edit(movePatch('x'))
      ..edit(movePatch('y', elementId: 'e2'));
    final attempt = client.claim(['y']);
    return client..must(BatchRefused(attempt, BatchRefusal.editAccessRemoved));
  }),
  Row('never sent, upgrade required', () {
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
  'user: discard the unreadable entry': (c) =>
      const UserDiscarded('unreadable/0'),
  'page-a restored': (c) => PageRestored('page-a', const {'x': 'x3'}),
  'base: strategy and every page read as they are': (c) => BaseArrived(
    HeaderRead(
      strategy: c.base.strategy,
      pages: c.base.pages.toList(),
      settings: c.base.settings.toList(),
    ),
  ),
  'base: page-a read with the item at revision 2': (c) => BaseArrived(
    PageRead(
      page: page('page-a', sortIndex: 0),
      settings: settings('page-a'),
      elements: [element('e1', revision: 2), element('e2')],
      lineupGroups: const [],
    ),
  ),
  'base: page-b gone': (c) => const BaseArrived(PageGone('page-b')),
  'base: strategy gone': (c) => const BaseArrived(StrategyGone()),
};

String describe(Client client, String id) {
  final entry = client.queue.entry(id);
  if (entry == null) return 'gone';
  final view = entryViews(client.queue, client.at)[id];
  return switch (entry) {
    PendingOp() =>
      '${view!.state}, ${view.go}${view.holds.isEmpty ? '' : ', ${view.holds.join(', ')}'}',
    RetiredOp() => 'retired format',
    UnreadableEntry() => 'unreadable entry',
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
        ...effects.map(
          (effect) => switch (effect) {
            OpRemoved(:final opId, :final cause) => 'removes $opId ($cause)',
            SendBatch(:final attempt, :final ops) =>
              'sends attempt $attempt (${ops.map((op) => op.opId).join(', ')})',
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
      '`viewsOf` in `lib/src/cloud/queue.dart`. Run with '
      '`UPDATE_TRANSITIONS=1` to rewrite.',
    )
    ..writeln()
    ..writeln(
      'Each section builds a queue by real events until op `x` is in that '
      'state, then applies one event. The state, why it needs the user and '
      'its holds are derived from the stored facts after every event. Events '
      'that do not apply are listed after the table; the queue is left as it '
      'was.',
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
      final result = outcome(
        fresh,
        transition(fresh.queue, make(fresh), now: fresh.at),
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
        expect(
          transition(client.queue, make(client), now: client.at),
          isA<Step>(),
        );
      }
    }
  });

  test('every kind of entry and every standing has a row', () {
    final kinds = <Kind>{};
    final standings = <Standing>{};
    for (final row in rows) {
      final client = row.build();
      final views = entryViews(client.queue, client.at);
      kinds.add(kindOf(client.queue.entry(row.subject)!, views[row.subject]));
      standings.add(standingOf(client.queue));
    }
    expect(kinds, Kind.values.toSet());
    expect(standings, Standing.values.toSet());
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
