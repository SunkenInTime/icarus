import 'dart:io';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_support.dart';
import 'support.dart';

PageRead readOf(
  String pageId, {
  List<ElementRow> elements = const [],
  int settingsRevision = 1,
}) => PageRead(
  page: page(pageId, sortIndex: 0),
  settings: ReadablePageSettings(
    pagePublicId: pageId,
    settings: defaultSettings,
    revision: settingsRevision,
  ),
  elements: elements,
  lineupGroups: const [],
);

void main() {
  group('1: a copy or a delete waits for earlier work on its page', () {
    test(
      'a copy waits for a move whose answer was lost and is backing off',
      () {
        final queue = run(edits([movePatch('move')]), [
          BatchClaimed(attempt('a1'), ['move']),
          TransportFailed('a1', TransportFailure.network, at: now),
          userEdits(pageAdd('copy', 'page-c', copyFrom: 'page-a')),
        ]);
        expect(
          holdsFor(queue, 'copy'),
          contains(BehindPageWork('page-a', ['move'])),
        );
        expect(
          notApplicable(
            transition(
              queue,
              BatchClaimed(attempt('a2'), ['copy']),
              now: now.add(const Duration(minutes: 1)),
            ),
          ),
          isA<HeldBack>(),
        );
      },
    );

    test('a batch keeps list order: a delete never goes ahead of an '
        'earlier edit of its page', () {
      final queue = run(CloudQueue.empty, [
        userEdits(movePatch('edit')),
        deleting(pageDelete('delete', 'page-a'), seenOf('Page 1')),
      ]);
      expect(
        notApplicable(
          transition(
            queue,
            BatchClaimed(attempt('a1'), ['delete', 'edit']),
            now: now,
          ),
        ),
        isA<OutOfOrder>(),
      );
    });

    test('a delete may go in the same batch as the earlier work on its page, '
        'after it', () {
      final queue = run(CloudQueue.empty, [
        userEdits(movePatch('edit')),
        UserEdited(plain(pageDelete('delete', 'page-a'))),
      ]);
      expect(holdsFor(queue, 'delete'), [
        BehindPageWork('page-a', ['edit']),
      ]);
      final claimed = run(queue, [
        BatchClaimed(attempt('a1'), ['edit', 'delete']),
      ]);
      expect(stateOf(claimed, 'delete'), isA<Claimed>());
    });

    test('a patch that does not carry its page records the page it was made '
        'on, and cannot be made without one', () {
      expect(editOf(movePatch('p')), isA<NeedsRowPage>());
      final queue = edits([movePatch('p')]);
      expect(entryOf(queue, 'p').scope, const OnPage('page-a'));
      final behind = run(CloudQueue.empty, [
        UserEdited(plain(pageDelete('delete', 'page-a'))),
        userEdits(movePatch('after')),
      ]);
      expect(
        holdsFor(behind, 'after'),
        contains(const BehindPageDelete('delete', 'page-a')),
      );
    });
  });

  group('2: an answer advances a follower only when it landed exactly', () {
    CloudQueue moveThenDelete() => run(CloudQueue.empty, [
      userEdits(movePatch('move', merge: FieldMerge(fields: ['position']))),
      BatchClaimed(attempt('a1'), ['move']),
      userEdits(elementDelete('delete', expected: 2)),
    ]);

    test('a merge that brought in a teammate\'s rotation leaves the delete '
        'checked against what the user saw', () {
      final result = stepped(
        transition(
          moveThenDelete(),
          answered(const AppliedAnswer('move', revision: 3)),
          now: now,
        ),
      );
      final delete = entryOf(result.queue, 'delete');
      expect((delete.op as ElementDeleteOp).expectedElementRevision, 2);
      expect(result.effects.whereType<OpRebased>(), isEmpty);
    });

    test('a write that landed on exactly what it expected moves the '
        'follower', () {
      final queue = run(CloudQueue.empty, [
        userEdits(movePatch('move')),
        BatchClaimed(attempt('a1'), ['move']),
        userEdits(elementDelete('delete', expected: 2)),
        answered(const AppliedAnswer('move', revision: 2)),
      ]);
      expect(entryOf(queue, 'delete').against, const StackedOn('move', 2));
    });

    test('a strategy change made at 1 is not advanced over a teammate\'s '
        'rename', () {
      final queue = run(CloudQueue.empty, [
        userEdits(
          const StrategyPatchOp(
            opId: 'map',
            expectedStrategyRevision: 1,
            mapData: 'bind',
          ),
        ),
        BatchClaimed(attempt('a1'), ['map']),
        userEdits(
          const StrategyPatchOp(
            opId: 'name',
            expectedStrategyRevision: 2,
            name: 'B split',
          ),
        ),
        answered(const AppliedAnswer('map', revision: 3)),
      ]);
      expect(
        (entryOf(queue, 'name').op as StrategyPatchOp).expectedStrategyRevision,
        2,
      );
    });

    test('a noop that was not this client\'s write moves a follower only '
        'behind a whole write', () {
      final kept = run(CloudQueue.empty, [
        userEdits(movePatch('first', merge: FieldMerge(fields: ['position']))),
        BatchClaimed(attempt('a1'), ['first']),
        userEdits(elementDelete('second', expected: 2)),
        answered(
          const NoopAnswer('first', revision: 5, replay: NoopReplay.notApplied),
        ),
      ]);
      expect(
        (entryOf(kept, 'second').op as ElementDeleteOp).expectedElementRevision,
        2,
      );
      final moved = run(CloudQueue.empty, [
        userEdits(movePatch('first')),
        BatchClaimed(attempt('a1'), ['first']),
        userEdits(elementDelete('second', expected: 2)),
        answered(
          const NoopAnswer('first', revision: 5, replay: NoopReplay.notApplied),
        ),
      ]);
      expect(
        (entryOf(moved, 'second').op as ElementDeleteOp)
            .expectedElementRevision,
        5,
      );
    });
  });

  group('3: an accepted op cannot wait forever', () {
    test('a base the store already holds acknowledges the answer at once', () {
      final result = stepped(
        transition(
          run(edits([movePatch('move')]), [
            BatchClaimed(attempt('a1'), ['move']),
          ]),
          answered(
            const AppliedAnswer('move', revision: 2),
            base: const BaseHolds(2),
          ),
          now: now,
        ),
      );
      expect(result.queue.entries, isEmpty);
      expect(result.effects, [const OpRemoved('move', SeenInBase())]);
    });

    test(
      'a page or a strategy going settles every accepted entry under it',
      () {
        final accepted = run(
          edits([
            movePatch('move'),
            elementAdd('add', elementId: 'e5', pageId: 'page-b'),
          ]),
          [
            BatchClaimed(attempt('a1'), ['move', 'add']),
            answered(const AppliedAnswer('move', revision: 2)),
            answered(const AppliedAnswer('add', revision: 1)),
          ],
        );
        final pageGone = run(accepted, [const BaseArrived(PageGone('page-a'))]);
        expect(pageGone.entries.map((entry) => entry.id), ['add']);
        final strategyGone = run(accepted, [const BaseArrived(StrategyGone())]);
        expect(strategyGone.entries, isEmpty);
        expect(strategyGone.standing, Standing.deletedOnServer);
      },
    );
  });

  group('4: a page-delete check is tied to the seen page it checked', () {
    final seen = seenOf(
      'Page 1',
      content: {const SeenSettings(): 1, const SeenElement('e1'): 1},
    );

    test('a passed check is void once an earlier own edit changes what the '
        'delete expects', () {
      final queue = run(CloudQueue.empty, [
        deleting(pageDelete('delete', 'page-a'), seen),
        BaseArrived(readOf('page-a', elements: [element('e1')])),
      ]);
      expect(holdsFor(queue, 'delete'), isEmpty);
      final withEdit = queueOf([
        pending(movePatch('edit'), Claimed(attempt('a1'), const NeverSent())),
        ...queue.entries.map(
          (entry) => switch (entry) {
            final PendingOp op => pending(
              op.op,
              op.state,
              place: 1,
              work: op.work,
            ),
            _ => entry,
          },
        ),
      ], checks: queue.session.deleteChecks);
      final answeredQueue = run(withEdit, [
        answered(const AppliedAnswer('edit', revision: 2)),
      ]);
      expect(holdsFor(answeredQueue, 'delete'), [
        const AwaitingPageRead('page-a'),
      ]);
    });

    test('the check waits until earlier work on the page has settled, so the '
        'user\'s own edit is not taken for a teammate\'s', () {
      final queue = run(CloudQueue.empty, [
        userEdits(movePatch('edit')),
        deleting(pageDelete('delete', 'page-a'), seen),
        BatchClaimed(attempt('a1'), ['edit']),
        BaseArrived(readOf('page-a', elements: [element('e1', revision: 2)])),
      ]);
      expect(
        (entryOf(queue, 'delete').work as CheckedDelete).verdict,
        const AwaitingCheck(),
      );
      final settled = run(queue, [
        answered(const AppliedAnswer('edit', revision: 2)),
        BaseArrived(readOf('page-a', elements: [element('e1', revision: 2)])),
      ]);
      expect(holdsFor(settled, 'delete'), isEmpty);
      expect(
        (entryOf(settled, 'delete').work as CheckedDelete).verdict,
        const AwaitingCheck(),
      );
    });
  });

  group('5: a claim is an attempt with one client id', () {
    test(
      'an answer unknown op keeps the client id it was first sent under',
      () {
        final queue = run(
          edits([movePatch('a'), movePatch('b', elementId: 'e2')]),
          [
            BatchClaimed(attempt('a1'), ['a']),
            const AppRestarted(),
          ],
        );
        expect(
          notApplicable(
            transition(
              queue,
              BatchClaimed(attempt('a2', client: 'client-2'), ['a', 'b']),
              now: now,
            ),
          ),
          isA<OtherClient>(),
        );
        final split = run(queue, [
          BatchClaimed(attempt('a2', client: 'client-2'), ['b']),
          BatchClaimed(attempt('a3'), ['a']),
        ]);
        expect((stateOf(split, 'b') as Claimed).attempt.clientId, 'client-2');
        expect((stateOf(split, 'a') as Claimed).attempt.clientId, clientId);
      },
    );

    test('a late failure of an old attempt leaves a newer claim alone', () {
      final queue = run(edits([movePatch('a')]), [
        BatchClaimed(attempt('a1'), ['a']),
        TransportFailed('a1', TransportFailure.timeout, at: now),
        BatchClaimed(attempt('a2'), ['a']),
      ], at: now.add(const Duration(minutes: 1)));
      expect(
        notApplicable(
          transition(
            queue,
            TransportFailed('a1', TransportFailure.timeout, at: now),
            now: now,
          ),
        ),
        isA<NoneClaimed>(),
      );
      expect((stateOf(queue, 'a') as Claimed).attempt.id, 'a2');
    });

    test('an attempt id is used once at a time', () {
      final queue = run(
        edits([movePatch('a'), movePatch('b', elementId: 'e2')]),
        [
          BatchClaimed(attempt('a1'), ['a']),
        ],
      );
      expect(
        notApplicable(
          transition(queue, BatchClaimed(attempt('a1'), ['b']), now: now),
        ),
        isA<AttemptTaken>(),
      );
    });
  });

  test('6: work behind a page delete that lands is stopped with a notice', () {
    final queue = run(CloudQueue.empty, [
      UserEdited(plain(pageDelete('delete', 'page-a'))),
      userEdits(elementAdd('after', pageId: 'page-a')),
      BatchClaimed(attempt('a1'), ['delete']),
    ]);
    final result = stepped(
      transition(
        queue,
        answered(const AppliedAnswer('delete', revision: 2)),
        now: now,
      ),
    );
    expect(
      stateOf(result.queue, 'after'),
      const Unsent(NeverSent(), NeedsUser(OnDeletedPage('page-a'))),
    );
    expect(result.effects, contains(WorkOnDeletedPage('page-a', ['after'])));
    final restored = run(result.queue, [PageRestored('page-a', const {})]);
    expect(stateOf(restored, 'after'), neverSentFree);
  });

  group('decisions', () {
    test('an answer unknown past the server\'s memory needs the user unless '
        'the server will check it', () {
      final unchecked = run(
        edits([
          movePatch('a', merge: FieldMerge(fields: ['position'])),
        ]),
        [
          BatchClaimed(attempt('a1'), ['a']),
          TransportFailed('a1', TransportFailure.network, at: now),
        ],
      );
      final later = now.add(
        serverRemembersAnswersFor + const Duration(hours: 1),
      );
      expect(
        stateOf(run(unchecked, [const ConnectionReturned()], at: later), 'a'),
        isA<Unsent>().having(
          (state) => (state.delivery as AnswerUnknown).retry,
          'retry',
          const ServerForgotAnswer(),
        ),
      );
      final checked = run(edits([movePatch('b')]), [
        BatchClaimed(attempt('a1'), ['b']),
        TransportFailed('a1', TransportFailure.network, at: now),
      ]);
      expect(
        ((stateOf(run(checked, [const ConnectionReturned()], at: later), 'b')
                        as Unsent)
                    .delivery
                as AnswerUnknown)
            .retry,
        isNot(const ServerForgotAnswer()),
      );
    });

    test('the window matches the server\'s purge of op records', () {
      final source = File('../../convex/maintenance.ts').readAsStringSync();
      final days = RegExp(
        r'const DAYS_30_MS = (\d+) \* 24 \* 60 \* 60 \* 1000;',
      ).firstMatch(source);
      expect(days, isNotNull);
      expect(
        Duration(days: int.parse(days!.group(1)!)),
        serverRemembersAnswersFor,
      );
      expect(source, contains('Date.now() - DAYS_30_MS'));
    });

    test('Keep mine replaces the op in place for the same row only, and later '
        'edits of that row wait behind the replacement', () {
      final queue = run(CloudQueue.empty, [
        userEdits(movePatch('first')),
        userEdits(movePatch('other', elementId: 'e2')),
        BatchClaimed(attempt('a1'), ['first', 'other']),
        answered(
          const RejectedAnswer(
            'first',
            RejectionReason.revisionMismatch,
            NoServerCopy(),
          ),
        ),
        userEdits(movePatch('later', expected: 2, x: 30)),
      ]);
      expect(
        notApplicable(
          transition(
            queue,
            UserKeptMine('first', movePatch('mine', elementId: 'e2')),
            now: now,
          ),
        ),
        isA<OtherRow>(),
      );
      final kept = run(queue, [
        UserKeptMine('first', movePatch('mine', expected: 4, x: 10)),
      ]);
      expect(kept.entries.map((entry) => entry.id), ['mine', 'other', 'later']);
      expect(holdsFor(kept, 'later'), [const BehindEarlierEdit('mine')]);
      expect(entryOf(kept, 'later').against, const StackedOn('mine', 2));
    });

    test('a lasting standing governs later edits and claims', () {
      final gone = run(edits([movePatch('a')]), [
        const BaseArrived(StrategyGone()),
        userEdits(movePatch('b', elementId: 'e2')),
      ]);
      expect(gone.standing, Standing.deletedOnServer);
      expect(
        notApplicable(
          transition(gone, BatchClaimed(attempt('a1'), ['b']), now: now),
        ),
        const TypeMatcher<StandingBlocks>(),
      );
      expect(
        syncStateOf(
          Tally.of(gone),
          network: Network.online,
          signedIn: SignedIn.thisAccount,
        ),
        isA<KeptForDeletedStrategy>(),
      );
      expect(run(gone, [const UserDiscarded('b')]).entries, hasLength(1));
    });

    test('a live op is sent without checks until a disconnect, restart or '
        'failed send makes it checked, never the other way', () {
      final merge = FieldMerge(fields: ['position'], base: {'position': null});
      final live = run(CloudQueue.empty, [
        const ConnectionReturned(),
        userEdits(movePatch('a', merge: merge)),
      ]);
      expect(entryOf(live, 'a').policy, SendPolicy.live);
      final sent = sendForm(entryOf(live, 'a').op, SendPolicy.live);
      expect((sent as ElementPatchOp).merge!.base, isNull);
      final dropped = run(live, [
        const ConnectionLost(),
        const ConnectionReturned(),
      ]);
      expect(entryOf(dropped, 'a').policy, SendPolicy.checked);
      expect(
        (sendForm(entryOf(dropped, 'a').op, SendPolicy.checked)
                as ElementPatchOp)
            .merge!
            .base,
        isNotNull,
      );
    });

    test('an op that is not JSON is refused at the door, and a failure at the '
        'last representable time still answers', () {
      final notJson = PageSettingsPatchOp(
        opId: 'nan',
        pagePublicId: 'page-a',
        settings: const PageSettings(
          agentSize: double.nan,
          abilitySize: 1,
          useNeutralTeamColors: false,
        ),
        expectedPageSettingsRevision: 1,
      );
      expect(
        notApplicable(
          transition(CloudQueue.empty, userEdits(notJson), now: now),
        ),
        isA<NotJson>(),
      );
      final last = DateTime.fromMillisecondsSinceEpoch(
        8640000000000000,
        isUtc: true,
      );
      final failed = run(edits([movePatch('a')]), [
        BatchClaimed(attempt('a1', at: last), ['a']),
        TransportFailed('a1', TransportFailure.network, at: last),
      ], at: last);
      expect(stateOf(failed, 'a'), isA<Unsent>());
    });
  });

  test('performance: 1,000 entries, a 40-op answer and a base read', () {
    var queue = CloudQueue.empty;
    for (var i = 0; i < 1000; i++) {
      queue = run(queue, [
        userEdits(movePatch('op$i', elementId: 'e$i', x: i.toDouble())),
      ]);
    }
    final ids = [for (var i = 0; i < 40; i++) 'op$i'];
    queue = run(queue, [BatchClaimed(attempt('a1'), ids)]);
    final clock = Stopwatch()..start();
    for (final id in ids) {
      queue = run(queue, [answered(AppliedAnswer(id, revision: 2))]);
    }
    final answering = clock.elapsedMicroseconds;
    clock.reset();
    queue = run(queue, [
      BaseArrived(
        readOf(
          'page-a',
          elements: [
            for (var i = 0; i < 1000; i++) element('e$i', revision: 2),
          ],
        ),
      ),
    ]);
    final reading = clock.elapsedMicroseconds;
    printOnFailure('answers: $answering us, base read: $reading us');
    expect(queue.entries, hasLength(960));
    expect(answering + reading, lessThan(2000000));
  });
}
