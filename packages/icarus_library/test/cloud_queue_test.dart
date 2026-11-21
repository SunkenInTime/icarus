import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_support.dart';
import 'support.dart';

List<Hold> holdsFor(CloudQueue queue, String opId, {DateTime? at}) =>
    holdsOf(queue, at ?? now)[opId] ?? const [];

void main() {
  group('holds come from the order of the list', () {
    test('a second edit of an item waits for the first one\'s answer', () {
      final queue = edits([movePatch('a'), movePatch('b', expected: 2)]);
      expect(holdsFor(queue, 'a'), isEmpty);
      expect(holdsFor(queue, 'b'), [const BehindEarlierEdit('a')]);
      expect(
        notApplicable(transition(queue, BatchClaimed(['a', 'b']), now: now)),
        isA<HeldBack>(),
      );
    });

    test('work on a page waits for the page\'s add', () {
      final queue = edits([
        pageAdd('add', 'page-c'),
        elementAdd('item', pageId: 'page-c'),
      ]);
      expect(holdsFor(queue, 'item'), [const BehindPageAdd('add', 'page-c')]);
      final landed = run(queue, [
        BatchClaimed(['add']),
        const OpAnswered(AppliedAnswer('add', revision: 2)),
      ]);
      expect(holdsFor(landed, 'item'), isEmpty);
    });

    test('a page change waits for the strategy change before it', () {
      final queue = edits([
        pageAdd('add', 'page-c'),
        pageReorder('move', 'page-b', expected: 2),
      ]);
      expect(holdsFor(queue, 'move'), [const BehindStrategyChange('add')]);
    });

    test('a rename waits for a renumbering before it, and the other way', () {
      final renameAfter = edits([
        pageReorder('move', 'page-b'),
        pageRename('rename', 'page-a'),
      ]);
      expect(holdsFor(renameAfter, 'rename'), [const BehindPageChange('move')]);
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
      final queue = run(edits([movePatch('a')]), [
        BatchClaimed(['a']),
        TransportFailed(['a'], TransportFailure.timeout, at: now),
      ]);
      final retryAt = now.add(const Duration(milliseconds: 600));
      expect(holdsFor(queue, 'a'), [UntilRetryTime(retryAt)]);
      expect(holdsFor(queue, 'a', at: retryAt), isEmpty);
    });

    test('a page delete waits for a read of its page in this session', () {
      final seen = seenOf('Page 1');
      final queue = run(CloudQueue.empty, [
        UserEdited(
          PageDeleteEdit(pageDelete('delete', 'page-a'), seen),
          clientId: clientId,
        ),
      ]);
      expect(holdsFor(queue, 'delete'), [const AwaitingPageRead('page-a')]);
      final read = run(queue, [
        BaseArrived(
          PageRead(
            page: page('page-a', sortIndex: 0),
            settings: settings('page-a'),
            elements: const [],
            lineupGroups: const [],
          ),
        ),
      ]);
      expect(holdsFor(read, 'delete'), isEmpty);
      expect(holdsFor(run(read, [const ConnectionLost()]), 'delete'), [
        const AwaitingPageRead('page-a'),
      ]);
      expect(holdsFor(run(read, [const AppRestarted()]), 'delete'), [
        const AwaitingPageRead('page-a'),
      ]);
    });
  });

  group('answers', () {
    test('an own write moves the next edit of the item onto its revision', () {
      final queue = edits([movePatch('a'), movePatch('b', expected: 2)]);
      final result = stepped(
        transition(
          run(queue, [
            BatchClaimed(['a']),
          ]),
          const OpAnswered(AppliedAnswer('a', revision: 4)),
          now: now,
        ),
      );
      expect(result.effects, [const OpRebased('b', 4)]);
      final b = result.queue.entry('b')! as PendingOp;
      expect((b.op as ElementPatchOp).expectedElementRevision, 4);
    });

    test('a noop that was not this client\'s write moves nothing', () {
      final queue = run(edits([movePatch('a'), movePatch('b', expected: 2)]), [
        BatchClaimed(['a']),
      ]);
      final result = stepped(
        transition(
          queue,
          const OpAnswered(
            NoopAnswer('a', revision: 4, replay: NoopReplay.notApplied),
          ),
          now: now,
        ),
      );
      expect(result.effects, isEmpty);
      expect(stateOf(result.queue, 'a'), const Accepted(4));
    });

    test('an accepted op stays until a base shows it', () {
      final accepted = run(edits([movePatch('a')]), [
        BatchClaimed(['a']),
        const OpAnswered(AppliedAnswer('a', revision: 2)),
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
      final claimed = run(edits([movePatch('a')]), [
        BatchClaimed(['a']),
      ]);
      expect(
        stateOf(
          run(claimed, [
            const OpAnswered(
              FailedAnswer(
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
        stateOf(
          run(claimed, [
            TransportFailed(['a'], TransportFailure.network, at: now),
          ]),
          'a',
        ),
        isA<Unsent>().having(
          (state) => state.delivery,
          'delivery',
          isA<AnswerUnknown>(),
        ),
      );
    });

    test('eight transport failures pause the op', () {
      var queue = edits([movePatch('a')]);
      var at = now;
      for (var i = 0; i < retriesBeforePause; i++) {
        at = at.add(const Duration(minutes: 1));
        queue = run(queue, [
          BatchClaimed(['a']),
          TransportFailed(['a'], TransportFailure.network, at: at),
        ], at: at);
      }
      expect(
        stateOf(queue, 'a'),
        isA<Unsent>().having(
          (state) => state.go,
          'go',
          const Paused(PauseReason.retriesExhausted),
        ),
      );
    });

    test('a batch refused whole proves it did not land', () {
      final claimed = run(edits([movePatch('a')]), [
        BatchClaimed(['a']),
      ]);
      final upgrade = stepped(
        transition(
          claimed,
          BatchRefused(['a'], BatchRefusal.upgradeRequired),
          now: now,
        ),
      );
      expect(
        stateOf(upgrade.queue, 'a'),
        const Unsent(NeverSent(), Paused(PauseReason.upgradeRequired)),
      );
      expect(upgrade.effects, [const HoldSendingForUpgrade()]);
      expect(
        stateOf(run(upgrade.queue, [const AppRestarted()]), 'a'),
        neverSentFree,
      );
    });

    test('losing edit access pauses all work waiting to go', () {
      final queue = run(
        edits([movePatch('a'), movePatch('b', elementId: 'e2')]),
        [
          BatchClaimed(['a']),
          BatchRefused(['a'], BatchRefusal.editAccessRemoved),
        ],
      );
      for (final opId in ['a', 'b']) {
        expect(
          stateOf(queue, opId),
          const Unsent(NeverSent(), Paused(PauseReason.editAccessRemoved)),
        );
      }
    });

    test('a deleted strategy keeps unanswered work for the user', () {
      final queue = run(
        edits([movePatch('a'), movePatch('b', elementId: 'e2')]),
        [
          BatchClaimed(['a']),
          const OpAnswered(AppliedAnswer('a', revision: 2)),
        ],
      );
      final gone = stepped(
        transition(queue, const BaseArrived(StrategyGone()), now: now),
      );
      expect(gone.effects, [
        const OpRemoved('a', LandedBeforeStrategyDeleted()),
      ]);
      expect(
        stateOf(gone.queue, 'b'),
        const Unsent(NeverSent(), NeedsUser(StrategyDeleted())),
      );
    });
  });

  group('page delete checks', () {
    final seen = seenOf(
      'Page 1',
      content: {const SeenSettings(): 1, const SeenElement('e1'): 1},
    );

    CloudQueue deleting() => run(CloudQueue.empty, [
      UserEdited(PlainEdit(movePatch('move')), clientId: clientId),
      UserEdited(
        PageDeleteEdit(pageDelete('delete', 'page-a'), seen),
        clientId: clientId,
      ),
    ]);

    PageRead readWith(List<ElementRow> elements) => PageRead(
      page: page('page-a', sortIndex: 0),
      settings: settings('page-a'),
      elements: elements,
      lineupGroups: const [],
    );

    test('this device\'s own landed edit is not taken for a teammate\'s', () {
      final landed = run(deleting(), [
        BatchClaimed(['move']),
        const OpAnswered(AppliedAnswer('move', revision: 2)),
        BaseArrived(readWith([element('e1', revision: 2)])),
      ]);
      expect(landed.deletesCheckedThisSession, contains('delete'));
      expect(stateOf(landed, 'delete'), neverSentFree);
    });

    test('a teammate\'s edit holds the delete for the user', () {
      final changed = run(deleting(), [
        BaseArrived(readWith([element('e1', revision: 3)])),
      ]);
      expect(
        stateOf(changed, 'delete'),
        const Unsent(
          NeverSent(),
          NeedsUser(HeldPageDelete(HeldDeleteCause.pageChanged)),
        ),
      );
      final anyway = run(changed, [const UserDeletedAnyway('delete')]);
      expect(stateOf(anyway, 'delete'), neverSentFree);
      expect(holdsFor(anyway, 'delete'), isEmpty);
    });

    test('a page whose content was never read is held', () {
      final queue = run(CloudQueue.empty, [
        UserEdited(
          PageDeleteEdit(
            pageDelete('delete', 'page-a'),
            const SeenPage(
              name: 'Page 1',
              isAttack: true,
              content: ContentNeverRead(),
            ),
          ),
          clientId: clientId,
        ),
        BaseArrived(readWith(const [])),
      ]);
      expect(
        stateOf(queue, 'delete'),
        const Unsent(
          NeverSent(),
          NeedsUser(HeldPageDelete(HeldDeleteCause.contentNeverRead)),
        ),
      );
    });
  });

  group('the defects the states rule out', () {
    test('#631: an undo after a lost answer never removes the sent op', () {
      final lost = run(edits([movePatch('edit', x: 50)]), [
        BatchClaimed(['edit']),
        TransportFailed(['edit'], TransportFailure.network, at: now),
      ]);
      final undone = run(lost, [
        UserEdited(
          PlainEdit(movePatch('undo', expected: 2, x: 10)),
          clientId: clientId,
        ),
      ]);
      expect(stateOf(undone, 'edit'), isA<Unsent>());
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
      final answered = run(undone, [
        BatchClaimed(['edit']),
        const OpAnswered(
          NoopAnswer(
            'edit',
            revision: 2,
            replay: NoopReplay.appliedWhenFirstReceived,
          ),
        ),
      ], at: now.add(const Duration(minutes: 1)));
      expect(stateOf(answered, 'edit'), const Accepted(2));
      expect(holdsFor(answered, 'undo'), isEmpty);
    });

    test('#645: no event writes an older op over a newer one', () {
      final queue = edits([movePatch('first', x: 1)]);
      final newer = run(queue, [
        UserEdited(
          PlainEdit(movePatch('second', expected: 2, x: 2)),
          clientId: clientId,
        ),
      ]);
      expect(
        notApplicable(
          transition(
            newer,
            UserEdited(PlainEdit(movePatch('first', x: 1)), clientId: clientId),
            now: now,
          ),
        ),
        isA<OpIdTaken>(),
      );
      expect(newer.entries.map((entry) => entry.opId), ['first', 'second']);
    });

    test('#646: Use cloud removes only the refused op, never later edits', () {
      final queue = run(edits([movePatch('refused')]), [
        BatchClaimed(['refused']),
        const OpAnswered(
          RejectedAnswer(
            'refused',
            RejectionReason.revisionMismatch,
            NoServerCopy(),
          ),
        ),
        UserEdited(
          PlainEdit(movePatch('later', elementId: 'e2')),
          clientId: clientId,
        ),
      ]);
      final result = stepped(
        transition(queue, const UserUsedCloud('refused'), now: now),
      );
      expect(result.queue.entries.map((entry) => entry.opId), ['later']);
      expect(stateOf(result.queue, 'later'), neverSentFree);
      expect(result.effects, [
        const OpRemoved(
          'refused',
          RemovedByUser(UserRemoval.usedCloud, Landing.notLanded),
        ),
      ]);
    });

    test('a claim released before transport is still never sent, and a '
        'restart while claimed is answer unknown with no failure counted', () {
      final claimed = run(edits([movePatch('a')]), [
        BatchClaimed(['a']),
      ]);
      expect(
        stateOf(
          run(claimed, [
            ClaimReleased(['a']),
          ]),
          'a',
        ),
        neverSentFree,
      );
      expect(
        stateOf(run(claimed, [const AppRestarted()]), 'a'),
        const Unsent(
          AnswerUnknown(
            failures: 0,
            retryAt: RetryNow(),
            cause: AppClosedWhileSending(),
          ),
          Free(),
        ),
      );
    });

    test('a duplicated or late answer changes nothing', () {
      final accepted = run(edits([movePatch('a')]), [
        BatchClaimed(['a']),
        const OpAnswered(AppliedAnswer('a', revision: 2)),
      ]);
      expect(
        notApplicable(
          transition(
            accepted,
            const OpAnswered(
              RejectedAnswer(
                'a',
                RejectionReason.revisionMismatch,
                NoServerCopy(),
              ),
            ),
            now: now,
          ),
        ),
        isA<NotInThatState>(),
      );
    });
  });

  test('an op past the size the server takes needs the user at once', () {
    final huge = ElementPatchOp(
      opId: 'huge',
      elementPublicId: 'e1',
      expectedElementRevision: 1,
      payload: agentPayload('e1', {
        'points': List.filled(maxCloudArrayEntries + 1, 0),
      }),
    );
    expect(
      stateOf(edits([huge]), 'huge'),
      const Unsent(NeverSent(), NeedsUser(Oversized())),
    );
  });
}
