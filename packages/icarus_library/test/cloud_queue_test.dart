import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_support.dart';
import 'support.dart';

CloudQueue sentOnce(List<StrategyOp> ops, List<String> claim) =>
    run(edits(ops), [BatchClaimed(attempt('a1'), claim)]);

void main() {
  group('holds come from the order of the list', () {
    test('a second edit of an item waits for the first one\'s answer', () {
      final queue = run(sentOnce([movePatch('a')], ['a']), [
        userEdits(movePatch('b', expected: 2)),
        TransportFailed('a1', TransportFailure.network, at: now),
      ]);
      expect(holdsFor(queue, 'b'), [const BehindEarlierEdit('a')]);
    });

    test('work on a page waits for the page\'s add', () {
      final queue = edits([
        pageAdd('add', 'page-c'),
        elementAdd('item', pageId: 'page-c'),
      ]);
      expect(holdsFor(queue, 'item'), [const BehindPageAdd('add', 'page-c')]);
    });

    test('a page change waits for the strategy change before it', () {
      final queue = run(sentOnce([pageAdd('add', 'page-c')], ['add']), [
        userEdits(pageReorder('move', 'page-b', expected: 2)),
      ]);
      expect(holdsFor(queue, 'move'), [const BehindStrategyChange('add')]);
    });

    test('a rename waits for a renumbering before it, and the other way', () {
      final renameAfter = edits([
        pageReorder('move', 'page-b'),
        pageRename('rename', 'page-a'),
      ]);
      expect(
        holdsFor(renameAfter, 'rename'),
        contains(const BehindPageChange('move')),
      );
      final moveAfter = edits([
        pageRename('rename', 'page-a'),
        pageReorder('move', 'page-b'),
      ]);
      expect(holdsFor(moveAfter, 'move'), [const BehindPageChange('rename')]);
    });

    test('an edit made after a page delete waits for it; one made before '
        'does not, whatever the clock says', () {
      final after = edits([
        pageDelete('delete', 'page-a'),
        elementAdd('item', pageId: 'page-a'),
      ]);
      expect(holdsFor(after, 'item'), [
        const BehindPageDelete('delete', 'page-a'),
      ]);
      final before = edits([
        elementAdd('item', pageId: 'page-a'),
        pageDelete('delete', 'page-a'),
      ]);
      expect(holdsFor(before, 'item'), isEmpty);
    });

    test('a failed send waits for its retry time', () {
      final queue = run(sentOnce([movePatch('a')], ['a']), [
        TransportFailed('a1', TransportFailure.timeout, at: now),
      ]);
      final retryAt = now.add(const Duration(milliseconds: 600));
      expect(holdsFor(queue, 'a'), [UntilRetryTime(retryAt)]);
      expect(holdsFor(queue, 'a', at: retryAt), isEmpty);
    });
  });

  group('answers', () {
    test('an accepted op stays until a base shows it', () {
      final accepted = run(sentOnce([movePatch('a')], ['a']), [
        answered(const AppliedAnswer('a', revision: 2)),
      ]);
      PageRead readAt(int revision) => PageRead(
        page: page('page-a', sortIndex: 0),
        settings: settings('page-a'),
        elements: [element('e1', revision: revision)],
        lineupGroups: const [],
      );
      expect(run(accepted, [BaseArrived(readAt(1))]).entry('a'), isNotNull);
      final seen = stepped(
        transition(accepted, BaseArrived(readAt(2)), now: now),
      );
      expect(seen.queue.entries, isEmpty);
      expect(seen.effects, [const OpRemoved('a', SeenInBase())]);
    });

    test('a per-op failure and a transport failure are different events', () {
      final claimed = sentOnce([movePatch('a')], ['a']);
      expect(
        stateOf(
          run(claimed, [
            answered(
              const FailedAnswer(
                'a',
                KnownFailure(FailureCode.invalidPayload),
                'bad payload',
              ),
            ),
          ]),
          'a',
        ),
        const ServerRefused(
          FailedOnServer(
            KnownFailure(FailureCode.invalidPayload),
            'bad payload',
          ),
        ),
      );
      expect(
        (stateOf(
                  run(claimed, [
                    TransportFailed('a1', TransportFailure.network, at: now),
                  ]),
                  'a',
                )
                as Unsent)
            .delivery,
        isA<AnswerUnknown>(),
      );
    });

    test('eight transport failures exhaust retries, which only an op that '
        'was sent can reach', () {
      var queue = edits([movePatch('a')]);
      var at = now;
      for (var i = 0; i < retriesBeforePause; i++) {
        at = at.add(const Duration(minutes: 1));
        queue = run(queue, [
          BatchClaimed(attempt('try$i', at: at), ['a']),
          TransportFailed('try$i', TransportFailure.network, at: at),
        ], at: at);
      }
      expect(
        (stateOf(queue, 'a') as Unsent).delivery,
        isA<AnswerUnknown>().having(
          (delivery) => delivery.retry,
          'retry',
          const RetriesExhausted(),
        ),
      );
      final retried = run(queue, [const UserRetried('a')], at: at);
      expect(
        ((stateOf(retried, 'a') as Unsent).delivery as AnswerUnknown).retry,
        const RetryNow(),
      );
    });

    test('a batch refused whole proves it did not land', () {
      final upgrade = stepped(
        transition(
          sentOnce([movePatch('a')], ['a']),
          const BatchRefused('a1', BatchRefusal.upgradeRequired),
          now: now,
        ),
      );
      expect(stateOf(upgrade.queue, 'a'), neverSentFree);
      expect(upgrade.queue.standing, Standing.upgradeRequired);
      expect(upgrade.effects, [const HoldSendingForUpgrade()]);
      expect(
        run(upgrade.queue, [const AppRestarted()]).standing,
        Standing.good,
      );
    });

    test('losing edit access stops every claim until access is confirmed', () {
      final queue = run(
        sentOnce([movePatch('a'), movePatch('b', elementId: 'e2')], ['a']),
        [const BatchRefused('a1', BatchRefusal.editAccessRemoved)],
      );
      expect(queue.standing, Standing.editAccessLost);
      expect(
        notApplicable(
          transition(queue, BatchClaimed(attempt('a2'), ['a']), now: now),
        ),
        isA<StandingBlocks>(),
      );
      expect(run(queue, [const EditAccessConfirmed()]).standing, Standing.good);
    });
  });

  group('the defects the states rule out', () {
    test('#631: an undo after a lost answer never removes the sent op', () {
      final lost = run(sentOnce([movePatch('edit', x: 50)], ['edit']), [
        TransportFailed('a1', TransportFailure.network, at: now),
      ]);
      final undone = run(lost, [
        userEdits(movePatch('undo', expected: 2, x: 10)),
      ]);
      expect(
        (stateOf(undone, 'edit') as Unsent).delivery,
        isA<AnswerUnknown>(),
      );
      expect(holdsFor(undone, 'undo'), [const BehindEarlierEdit('edit')]);
      expect(
        notApplicable(
          transition(undone, const UserDiscarded('edit'), now: now),
        ),
        isA<NotInThatState>(),
      );
      final later = now.add(const Duration(minutes: 1));
      final answeredQueue = run(undone, [
        BatchClaimed(attempt('a2', at: later), ['edit']),
        answered(
          const NoopAnswer(
            'edit',
            revision: 2,
            replay: NoopReplay.appliedWhenFirstReceived,
          ),
          by: attempt('a2', at: later),
        ),
      ], at: later);
      expect(stateOf(answeredQueue, 'edit'), const Accepted(2));
      expect(holdsFor(answeredQueue, 'undo', at: later), isEmpty);
    });

    test('#645: no event writes an older op over a newer one', () {
      final newer = run(sentOnce([movePatch('first', x: 1)], ['first']), [
        userEdits(movePatch('second', expected: 2, x: 2)),
      ]);
      expect(
        notApplicable(
          transition(newer, userEdits(movePatch('first', x: 1)), now: now),
        ),
        isA<OpIdTaken>(),
      );
      expect(newer.entries.map((entry) => entry.id), ['first', 'second']);
    });

    test('#646: after Use cloud, later edits of the same item stay and are '
        'held until the base shows the cloud version, then go against it', () {
      final queue = run(sentOnce([movePatch('refused')], ['refused']), [
        userEdits(movePatch('later', expected: 2, x: 40)),
        userEdits(movePatch('elsewhere', elementId: 'e2')),
        answered(
          RejectedAnswer(
            'refused',
            RejectionReason.revisionMismatch,
            ServerSnapshot(
              target: SnapshotTarget.element,
              revision: 6,
              value: agentPayload('e1', const {}).toJson(),
            ),
          ),
        ),
      ]);
      final used = stepped(
        transition(queue, const UserUsedCloud('refused'), now: now),
      );
      expect(used.queue.entries.map((entry) => entry.id), [
        'later',
        'elsewhere',
      ]);
      expect(holdsFor(used.queue, 'later'), [const AwaitingCloudVersion(6)]);
      expect(holdsFor(used.queue, 'elsewhere'), isEmpty);
      final shown = run(used.queue, [
        BaseArrived(
          PageRead(
            page: page('page-a', sortIndex: 0),
            settings: settings('page-a'),
            elements: [element('e1', revision: 6)],
            lineupGroups: const [],
          ),
        ),
      ]);
      expect(holdsFor(shown, 'later'), isEmpty);
      expect(
        (entryOf(shown, 'later').op as ElementPatchOp).expectedElementRevision,
        2,
      );
    });

    test('a claim released before transport is still never sent, and a '
        'restart while claimed is answer unknown with no failure counted', () {
      final claimed = sentOnce([movePatch('a')], ['a']);
      expect(
        stateOf(run(claimed, [const ClaimReleased('a1')]), 'a'),
        neverSentFree,
      );
      expect(
        stateOf(run(claimed, [const AppRestarted()]), 'a'),
        Unsent(
          AnswerUnknown(
            clientId: clientId,
            firstSentAt: now,
            failures: 0,
            retry: const RetryNow(),
            cause: const AppClosedWhileSending(),
          ),
          const Free(),
        ),
      );
    });
  });

  group('folding', () {
    test('a nudge then a nudge of a never-sent op is one op under the new '
        'id', () {
      final step = stepped(
        transition(
          edits([movePatch('a')]),
          userEdits(movePatch('b', expected: 2, x: 30)),
          now: now,
        ),
      );
      expect(step.queue.entries.map((entry) => entry.id), ['b']);
      final folded = entryOf(step.queue, 'b').op as ElementPatchOp;
      expect(folded.expectedElementRevision, 1);
      expect(folded.payload!.data['position'], {'dx': 30, 'dy': 0});
      expect(step.effects, [const OpRemoved('a', FoldedInto('b'))]);
    });

    test('a never-sent add then a delete cancels both', () {
      final step = stepped(
        transition(
          edits([elementAdd('add', elementId: 'e7')]),
          userEdits(elementDelete('delete', elementId: 'e7')),
          now: now,
        ),
      );
      expect(step.queue.entries, isEmpty);
      expect(step.effects, [const OpRemoved('add', CancelledBy('delete'))]);
    });

    test('nothing folds into an op that was claimed, sent, accepted, refused '
        'or needs the user', () {
      final claimed = sentOnce([movePatch('a')], ['a']);
      final states = <CloudQueue>[
        claimed,
        run(claimed, [
          TransportFailed('a1', TransportFailure.network, at: now),
        ]),
        run(claimed, [answered(const AppliedAnswer('a', revision: 2))]),
        run(claimed, [
          answered(
            const RejectedAnswer(
              'a',
              RejectionReason.revisionMismatch,
              NoServerCopy(),
            ),
          ),
        ]),
        run(edits([movePatch('a')]), [
          const WorkNoLongerFits('a', serverRevision: 3),
        ]),
      ];
      for (final queue in states) {
        final after = run(queue, [userEdits(movePatch('b', expected: 2))]);
        expect(after.entries.map((entry) => entry.id), ['a', 'b']);
      }
    });

    test('nothing folds across a later op of the same row that is not '
        'never-sent, or across a renumbering', () {
      final across = run(edits([movePatch('a')]), [
        userEdits(movePatch('other', elementId: 'e2')),
        userEdits(pageReorder('move', 'page-b')),
        userEdits(movePatch('b', expected: 2)),
      ]);
      expect(across.entries.map((entry) => entry.id), [
        'a',
        'other',
        'move',
        'b',
      ]);
    });
  });

  group('sync state', () {
    test('it says all saved only when no entry is left', () {
      final accepted = run(sentOnce([movePatch('a')], ['a']), [
        answered(const AppliedAnswer('a', revision: 2)),
      ]);
      expect(
        syncStateOf(
          Tally.of(accepted),
          network: Network.online,
          signedIn: SignedIn.thisAccount,
        ),
        isA<Waiting>().having(
          (state) => state.why,
          'why',
          WaitingWhy.confirming,
        ),
      );
      expect(
        syncStateOf(
          Tally.of(CloudQueue.empty),
          network: Network.online,
          signedIn: SignedIn.thisAccount,
        ),
        const AllSaved(),
      );
    });

    test('a deleted strategy\'s kept work shows for the whole account', () {
      final healthy = Tally.empty;
      final gone = Tally.of(
        run(edits([movePatch('a')]), [const BaseArrived(StrategyGone())]),
      );
      expect(
        accountSyncState(
          [healthy, gone],
          network: Network.online,
          signedIn: SignedIn.thisAccount,
        ),
        isA<KeptForDeletedStrategy>(),
      );
    });

    test('it can give each of today\'s five chips', () {
      String chip(SyncState state, {bool editingText = false}) =>
          switch (state) {
            AllSaved() when editingText => 'editing',
            AllSaved() => 'synced',
            KeptForDeletedStrategy() ||
            UnreadableWork() ||
            NeedsYou() => 'attention',
            Waiting(why: WaitingWhy.upgradeRequired) => 'attention',
            Waiting(why: WaitingWhy.offline) => 'offline',
            Waiting() => 'syncing',
          };
      SyncState of(CloudQueue queue, {Network network = Network.online}) =>
          syncStateOf(
            Tally.of(queue),
            network: network,
            signedIn: SignedIn.thisAccount,
          );
      final waiting = edits([movePatch('a')]);
      expect(
        {
          chip(of(CloudQueue.empty)),
          chip(of(CloudQueue.empty), editingText: true),
          chip(of(waiting)),
          chip(of(waiting, network: Network.offline)),
          chip(
            of(
              run(sentOnce([movePatch('a')], ['a']), [
                answered(
                  const RejectedAnswer(
                    'a',
                    RejectionReason.deleted,
                    NoServerCopy(),
                  ),
                ),
              ]),
            ),
          ),
        },
        {'synced', 'editing', 'syncing', 'offline', 'attention'},
      );
    });
  });
}
