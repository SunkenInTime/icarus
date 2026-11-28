import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/codec.dart'
    show decodeEntry, entryToJson;
import 'package:icarus_library/src/cloud/op_facts.dart' show renamed;
import 'package:test/test.dart';

import 'cloud_server.dart';
import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

final strategyLife = strategyCreatedAt.millisecondsSinceEpoch;

final theyDeleted = withOp(initialRows(), pageDelete('their-drop', 'page-b'));

final theyRestored = initialRows().withRows([
  initialRows().strategy.rewritten(revision: theyDeleted.strategy.revision + 1),
]);

Future<void> commit(LibraryStore store, StrategyOp op) async => savedValue(
  await store.commitAs(testAccount, strategyId, op, seen: await seenIn(store)),
);

Future<void> listed(LibraryStore store, StrategyRowSet server) async {
  await recordAll(store, [await arrivalIn(store, headerReadOf(server))]);
  for (final page in server.pages) {
    if (page is LivePage) {
      await recordAll(store, [
        await arrivalIn(store, pageReadOf(server, page.publicId)),
      ]);
    }
  }
}

Future<EntryView> viewOf(LibraryStore store, String id) async =>
    (await syncOf(store)).views[id]!;

Future<List<String>> sendable(LibraryStore store) async => [
  for (final entry in (await syncOf(store)).queue.entries)
    if ((await syncOf(store)).views[entry.id]?.sendable ?? false) entry.id,
];

Future<SendBatch> answerAll(
  LibraryStore store,
  OpAnswer Function(StrategyOp) of,
) async {
  final sent = await claimAll(store);
  await recordAll(store, [
    for (final op in sent.ops) OpAnswered(sent.attempt, of(op), point: tick()),
  ]);
  return sent;
}

void main() {
  sentAgainTests();
  roundTwoTests();
  group(
    'an op is held while the server\'s rows hold its page in the trash',
    () {
      test('my edit on a page a teammate deleted waits, held for the trash, '
          'not sent, refused, or turned into a conflict', () async {
        final store = await openCloudStore(MemoryEngine(MemoryStorage()));
        await addCloud(store, initialRows());
        await commit(
          store,
          movePatch('mine', elementId: 'e3', pageId: 'page-b'),
        );
        await listed(store, theyDeleted);
        final view = await viewOf(store, 'mine');
        expect(view.state, const Waiting());
        expect(view.holds, [const PageInTrash('page-b')]);
        expect(view.sendable, isFalse);
        final cloud = await syncOf(store);
        expect(cloud.tally.waiting, {Underway.pageInTrash: 1});
        expect(cloud.tally.stillGoing, 1);
      });

      test('the hold is read from the rows, not stored: the queue record is '
          'the same, and a reopened store holds the op again', () async {
        final storage = MemoryStorage();
        var store = await openCloudStore(MemoryEngine(storage));
        await addCloud(store, initialRows());
        await commit(
          store,
          movePatch('mine', elementId: 'e3', pageId: 'page-b'),
        );
        final recorded = entryRecordOf(await syncOf(store), 'mine');
        await listed(store, theyDeleted);
        expect(entryRecordOf(await syncOf(store), 'mine'), recorded);
        await store.close();
        store = await openCloudStore(MemoryEngine(storage));
        await recordAll(store, [const AppRestarted(build: build)]);
        expect((await viewOf(store, 'mine')).holds, [
          const PageInTrash('page-b'),
        ]);
      });

      test('every kind the server refuses on a page in the trash is held; a '
          'page delete, which the server answers as nothing to do, and a '
          'strategy rename are not', () async {
        final base = strategyRows(
          elements: [
            element('e1'),
            element('e3', pageId: 'page-b'),
            element('e4', pageId: 'page-b'),
            element('e5', pageId: 'page-b'),
          ],
        );
        final deleted = withOp(base, pageDelete('their-drop', 'page-b'));
        final store = await openCloudStore(MemoryEngine(MemoryStorage()));
        await addCloud(store, base);
        final held = <StrategyOp>[
          elementAdd('add', elementId: 'e9', pageId: 'page-b'),
          movePatch('patch', elementId: 'e3', pageId: 'page-b'),
          const ElementReorderOp(
            opId: 'reorder',
            elementPublicId: 'e4',
            pagePublicId: 'page-b',
            sortIndex: 2,
            expectedElementRevision: 1,
          ),
          elementDelete('remove', elementId: 'e5', pageId: 'page-b'),
          movePatch('onto-b', elementId: 'e1', pageId: 'page-b'),
          const PagePatchOp(
            opId: 'rename-page',
            pagePublicId: 'page-b',
            expectedPageRevision: 1,
            name: 'Retake',
          ),
          const PageSettingsPatchOp(
            opId: 'settings',
            pagePublicId: 'page-b',
            settings: PageSettings(
              agentSize: 40,
              abilitySize: 30,
              useNeutralTeamColors: true,
            ),
            expectedPageSettingsRevision: 1,
          ),
          const PageReorderOp(
            opId: 'move-page',
            pagePublicId: 'page-b',
            sortIndex: 0,
            expectedStrategyRevision: 1,
          ),
        ];
        final server = Server()..rows = deleted;
        for (final op in held) {
          await commit(store, op);
          expect(
            server.copy().apply(clientId, op),
            isA<FailedAnswer>().having(
              (answer) => answer.code,
              'code',
              const KnownFailure(FailureCode.pageDeleted),
            ),
            reason: '${op.opId} on the server',
          );
        }
        await listed(store, deleted);
        final views = (await syncOf(store)).views;
        for (final op in held) {
          expect(
            views[op.opId]!.holds,
            contains(const PageInTrash('page-b')),
            reason: op.opId,
          );
        }
        final noop = Server()..rows = theyDeleted;
        expect(
          noop.apply(clientId, pageDelete('drop', 'page-b', expected: 2)),
          isA<NoopAnswer>(),
        );
      });

      test('a page delete of a page already in the trash is sent and answered '
          'as nothing to do', () async {
        final store = await openCloudStore(MemoryEngine(MemoryStorage()));
        await addCloud(store, initialRows());
        await commit(store, pageDelete('drop', 'page-b'));
        await listed(store, theyDeleted);
        expect((await viewOf(store, 'drop')).sendable, isTrue);
        final server = Server()..rows = theyDeleted;
        final sent = await answerAll(store, (op) => server.apply(clientId, op));
        expect(sent.ops.map((op) => op.opId), ['drop']);
        expect((await syncOf(store)).queue.entries, isEmpty);
      });
    },
  );

  group('my own delete is not a teammate\'s', () {
    test('ops I queued on a page before my unsent delete of it go out first, '
        'as before', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      await commit(store, movePatch('mine', elementId: 'e3', pageId: 'page-b'));
      await commit(store, pageDelete('drop', 'page-b'));
      final server = Server()..rows = initialRows();
      final first = await answerAll(store, (op) => server.apply(clientId, op));
      expect(first.ops.map((op) => op.opId), ['mine']);
      await listed(store, server.rows);
      final second = await answerAll(store, (op) => server.apply(clientId, op));
      expect(second.ops.map((op) => op.opId), ['drop']);
      expect((await syncOf(store)).queue.entries, isEmpty);
    });

    test('when my delete comes back as nothing to do because a teammate got '
        'there first, my held ops on that page are let go with it', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      await commit(store, movePatch('mine', elementId: 'e3', pageId: 'page-b'));
      await commit(store, pageDelete('drop', 'page-b'));
      await listed(store, theyDeleted);
      expect(await sendable(store), ['drop']);
      final server = Server()..rows = theyDeleted;
      final sent = await claimAll(store);
      final effects = effectsOf(
        await recordAll(store, [
          OpAnswered(
            sent.attempt,
            server.apply(clientId, sent.ops.single),
            point: tick(),
          ),
        ]),
      );
      expect(
        effects,
        contains(const OpRemoved('mine', LetGoWithItsPage('drop'))),
      );
      expect((await syncOf(store)).queue.entries, isEmpty);
      expect(server.received, 1);
    });
  });

  test('a teammate\'s restore lifts the hold once the page is live and read, '
      'and the op is judged and lands as usual', () async {
    final store = await openCloudStore(MemoryEngine(MemoryStorage()));
    await addCloud(store, initialRows());
    await commit(store, movePatch('mine', elementId: 'e3', pageId: 'page-b'));
    await listed(store, theyDeleted);
    expect((await viewOf(store, 'mine')).sendable, isFalse);
    await listed(store, theyRestored);
    final view = await viewOf(store, 'mine');
    expect(view.holds, isEmpty, reason: '$view');
    expect(view.sendable, isTrue, reason: '$view');
    final server = Server()..rows = theyRestored;
    await answerAll(store, (op) => server.apply(clientId, op));
    expect(server.landed('mine'), isTrue);
    expect((await syncOf(store)).queue.entries, isEmpty);
  });

  group('held ops on one page hold nothing else back', () {
    test('a later edit on another page goes', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      await commit(store, movePatch('on-b', elementId: 'e3', pageId: 'page-b'));
      await listed(store, theyDeleted);
      await commit(store, movePatch('on-a', elementId: 'e1', pageId: 'page-a'));
      expect(await sendable(store), ['on-a']);
    });

    test('a later page add goes ahead of a held move of the deleted page, '
        'which would otherwise hold every later page op', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      await commit(
        store,
        const PageReorderOp(
          opId: 'move-b',
          pagePublicId: 'page-b',
          sortIndex: 0,
          expectedStrategyRevision: 1,
        ),
      );
      await listed(store, theyDeleted);
      await commit(
        store,
        pageAdd('add', 'page-c', expected: theyDeleted.strategy.revision),
      );
      expect(await sendable(store), ['add']);
      expect((await viewOf(store, 'move-b')).holds, [
        const PageInTrash('page-b'),
      ]);
    });

    test('a second edit of the same row waits with the first, held for the '
        'trash too', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      await commit(
        store,
        movePatch('first', elementId: 'e3', pageId: 'page-b'),
      );
      await commit(
        store,
        movePatch(
          'second',
          elementId: 'e3',
          pageId: 'page-b',
          x: 70,
          expected: 2,
        ),
      );
      await listed(store, theyDeleted);
      expect(await sendable(store), isEmpty);
      expect(
        (await viewOf(store, 'second')).holds,
        contains(const PageInTrash('page-b')),
      );
    });

    test('a copy of the page made before the delete goes; one made after it '
        'is stopped at commit for content not held', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      await commit(store, pageAdd('copy', 'page-c', copyFrom: 'page-b'));
      final copied = [
        for (final entry in (await syncOf(store)).queue.entries) entry.id,
      ];
      await listed(store, theyDeleted);
      expect(await sendable(store), ['copy']);
      final views = (await syncOf(store)).views;
      for (final id in copied) {
        expect(views[id]!.holds.whereType<PageInTrash>(), isEmpty, reason: id);
      }
      expect(
        await store.commitAs(
          testAccount,
          strategyId,
          pageAdd(
            'late-copy',
            'page-d',
            copyFrom: 'page-b',
            expected:
                (strategyOf(await store.readStrategy(strategyId)).strategy
                        as ReadableStrategy)
                    .revision,
          ),
          seen: await seenIn(store),
        ),
        isA<Refused<Committed, CommitRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          const CopyNeedsContent('page-b'),
        ),
      );
    });
  });

  test('a page list without the purged row sends the op to the user as page '
      'gone', () async {
    final store = await openCloudStore(MemoryEngine(MemoryStorage()));
    await addCloud(store, initialRows());
    await commit(store, movePatch('mine', elementId: 'e3', pageId: 'page-b'));
    await listed(store, theyDeleted);
    await listed(store, withoutPage(theyDeleted, 'page-b'));
    expect((await viewOf(store, 'mine')).state, const NeedsUser(RowPageGone()));
  });
}

Future<SendBatch> answerFrom(LibraryStore store, Server server) async {
  final sent = await claimAll(store);
  await recordAll(store, [
    for (final op in sent.ops)
      OpAnswered(sent.attempt, server.apply(clientId, op), point: tick()),
  ]);
  return sent;
}

Future<LibraryStore> editedBeforeTheyDeleted(List<StrategyOp> ops) async {
  final store = await openCloudStore(MemoryEngine(MemoryStorage()));
  await addCloud(store, initialRows());
  for (final op in ops) {
    await commit(store, op);
  }
  return store;
}

void sentAgainTests() {
  group('a change refused as its page deleted', () {
    test('waits, counted on its own, until a page list says where the page '
        'is: never needs the user for it', () async {
      final store = await editedBeforeTheyDeleted([
        movePatch('mine', elementId: 'e3', pageId: 'page-b'),
      ]);
      final server = Server()..rows = theyDeleted;
      await answerFrom(store, server);
      final cloud = await syncOf(store);
      final view = cloud.views['mine']!;
      expect(view.state, const Waiting());
      expect(view.holds, contains(const RefusedAsPageDeleted()));
      expect(cloud.tally.waiting, {Underway.refusedAsPageDeleted: 1});
      expect(cloud.tally.needingYou, 0);
      expect(
        resultsNeeded(cloud.queue, fixedClock()),
        contains(const PageListResult()),
      );
    });

    test('a page list showing it in the trash holds it', () async {
      final store = await editedBeforeTheyDeleted([
        movePatch('mine', elementId: 'e3', pageId: 'page-b'),
      ]);
      await answerFrom(store, Server()..rows = theyDeleted);
      await listed(store, theyDeleted);
      expect((await viewOf(store, 'mine')).holds, [
        const PageInTrash('page-b'),
      ]);
    });

    test(
      'a page list without the page sends it to the user as page gone',
      () async {
        final store = await editedBeforeTheyDeleted([
          movePatch('mine', elementId: 'e3', pageId: 'page-b'),
        ]);
        await answerFrom(store, Server()..rows = theyDeleted);
        await listed(store, withoutPage(theyDeleted, 'page-b'));
        expect(
          (await viewOf(store, 'mine')).state,
          const NeedsUser(RowPageGone()),
        );
      },
    );

    test('restored, it is sent again under a new id, in queue order, and '
        'lands once; a change for another page in the same batch landed the '
        'first time', () async {
      final store = await editedBeforeTheyDeleted([
        elementAdd('add', elementId: 'e9', pageId: 'page-b'),
        movePatch('move-a', elementId: 'e1', pageId: 'page-a'),
      ]);
      await commit(
        store,
        movePatch('patch', elementId: 'e9', pageId: 'page-b'),
      );
      final server = Server()..rows = theyDeleted;
      final first = await answerFrom(store, server);
      expect(first.ops.map((op) => op.opId), ['add', 'move-a']);
      expect(server.landed('move-a'), isTrue);
      expect(server.landed('add'), isFalse);
      server.rows = server.rows.withRows([
        theyRestored.page('page-b')!,
        server.rows.strategy.rewritten(
          revision: server.rows.strategy.revision + 1,
        ),
      ]);
      final effects = effectsOf(
        await recordAll(store, [
          await arrivalIn(store, headerReadOf(server.rows)),
        ]),
      );
      expect(
        effects,
        contains(OpRemoved('add', SentAgainAs(sentAgainId('add')))),
      );
      final queue = (await syncOf(store)).queue;
      expect(queue.entries.map((entry) => entry.id), [
        sentAgainId('add'),
        'patch',
      ]);
      final again = queue.entries.first as PendingOp;
      expect(
        again.op,
        renamed(
          elementAdd('add', elementId: 'e9', pageId: 'page-b'),
          sentAgainId('add'),
        ),
      );
      await listed(store, server.rows);
      final second = await answerFrom(store, server);
      expect(second.ops.map((op) => op.opId), [sentAgainId('add')]);
      await listed(store, server.rows);
      final third = await answerFrom(store, server);
      expect(third.ops.map((op) => op.opId), ['patch']);
      expect(server.landed(sentAgainId('add')), isTrue);
      expect(server.landed('patch'), isTrue);
      expect(
        server.rows.elements.where((row) => row.publicId == 'e9'),
        hasLength(1),
      );
      expect((await syncOf(store)).queue.entries, isEmpty);
    });

    test('its answer lost, it goes again under the same id, gets the recorded '
        'refusal back, and only then takes the new id', () async {
      var clock = fixedClock();
      final store = await openCloudStore(
        MemoryEngine(MemoryStorage()),
        clock: () => clock,
      );
      await addCloud(store, initialRows());
      await commit(store, movePatch('mine', elementId: 'e3', pageId: 'page-b'));
      final server = Server()..rows = theyDeleted;
      final lost = await claimAll(store);
      server.apply(clientId, lost.ops.single);
      await recordAll(store, [
        TransportFailed(lost.attempt, TransportFailure.network, at: clock),
      ]);
      clock = clock.add(const Duration(minutes: 10));
      final replay = await answerFrom(store, server);
      expect(replay.ops.map((op) => op.opId), ['mine']);
      expect(server.received, 1);
      expect(
        (await viewOf(store, 'mine')).holds,
        contains(const RefusedAsPageDeleted()),
      );
      server.rows = theyRestored;
      await listed(store, theyRestored);
      final again = await answerFrom(store, server);
      expect(again.ops.map((op) => op.opId), [sentAgainId('mine')]);
      expect(server.landed(sentAgainId('mine')), isTrue);
      expect(server.landed('mine'), isFalse);
    });

    test(
      'an element delete refused as its page deleted is sent again once, '
      'under its new id, however many page lists then show the page live',
      () async {
        final store = await editedBeforeTheyDeleted([
          elementDelete('remove', elementId: 'e3', pageId: 'page-b'),
        ]);
        final server = Server()..rows = theyDeleted;
        await answerFrom(store, server);
        expect(server.sends, 1);
        server.rows = theyRestored;
        await listed(store, theyRestored);
        final again = await answerFrom(store, server);
        expect(again.ops.map((op) => op.opId), [sentAgainId('remove')]);
        for (var list = 0; list < 2; list++) {
          await listed(store, server.rows);
          expect(await sendable(store), isEmpty);
        }
        expect(server.sends, 2);
        expect(server.landed(sentAgainId('remove')), isTrue);
        expect((await syncOf(store)).queue.entries, isEmpty);
      },
    );

    test('refused again as its page deleted with the page still listed live, '
        'it goes to the user', () async {
      final store = await editedBeforeTheyDeleted([
        movePatch('mine', elementId: 'e3', pageId: 'page-b'),
      ]);
      await answerFrom(store, Server()..rows = theyDeleted);
      await listed(store, theyRestored);
      final sent = await claimAll(store);
      expect(sent.ops.map((op) => op.opId), [sentAgainId('mine')]);
      await recordAll(store, [
        OpAnswered(
          sent.attempt,
          FailedAnswer(
            sentAgainId('mine'),
            const KnownFailure(FailureCode.pageDeleted),
            'PAGE_DELETED',
          ),
          point: tick(),
        ),
      ]);
      expect(
        (await viewOf(store, sentAgainId('mine'))).holds,
        contains(const RefusedAsPageDeleted()),
      );
      await listed(store, theyRestored);
      expect(
        (await viewOf(store, sentAgainId('mine'))).state,
        const NeedsUser(
          RefusedByServer(
            FailedOnServer(
              KnownFailure(FailureCode.pageDeleted),
              'PAGE_DELETED',
            ),
          ),
        ),
      );
    });
  });
}

Future<void> listedAt(
  LibraryStore store,
  StrategyRowSet server,
  ResultPoint point,
) async {
  final session = (await syncOf(store)).queue.session.number;
  await recordAll(store, [
    BaseArrived(headerReadOf(server), session: session, point: point),
  ]);
}

Future<List<QueueEffect>> answerOnly(
  LibraryStore store,
  List<String> opIds,
  Server server,
) async {
  final sent = effectsOf(
    await recordAll(store, [
      BatchClaimed(clientId: clientId, opIds: opIds, at: fixedClock()),
    ]),
  ).whereType<SendBatch>().single;
  return effectsOf(
    await recordAll(store, [
      for (final op in sent.ops)
        OpAnswered(sent.attempt, server.apply(clientId, op), point: tick()),
    ]),
  );
}

PendingOp pendingIn(CloudStrategy cloud, String id) =>
    cloud.queue.entry(id)! as PendingOp;

void roundTwoTests() {
  group('round 2', () {
    test(
      'A, B: a move onto the deleted page and back, my delete of it, then '
      'an edit on A: the edit waits behind the moves; only the move the '
      'server would refuse for the deleted page goes with my delete, and '
      'the move back, judged against the server row, asks the user',
      () async {
        final store = await openCloudStore(MemoryEngine(MemoryStorage()));
        await addCloud(store, initialRows());
        await commit(
          store,
          movePatch('to-b', elementId: 'e1', pageId: 'page-b'),
        );
        await commit(
          store,
          movePatch('to-a', elementId: 'e1', pageId: 'page-a', expected: 2),
        );
        await commit(store, pageDelete('drop', 'page-b'));
        await commit(
          store,
          movePatch('edit', elementId: 'e1', x: 70, expected: 3),
        );
        await listed(store, theyDeleted);
        final views = (await syncOf(store)).views;
        expect(views['to-b']!.holds, contains(const PageInTrash('page-b')));
        expect(views['to-a']!.holds, [
          const BehindEntry('to-b', Dependency.sameRow),
        ]);
        expect(
          views['edit']!.holds,
          contains(const BehindEntry('to-a', Dependency.sameRow)),
        );
        expect(await sendable(store), ['drop']);
        final effects = await answerOnly(store, [
          'drop',
        ], Server()..rows = theyDeleted);
        expect(
          effects.whereType<OpRemoved>().where(
            (effect) => effect.cause is LetGoWithItsPage,
          ),
          [const OpRemoved('to-b', LetGoWithItsPage('drop'))],
        );
        expect((await syncOf(store)).queue.entries.map((entry) => entry.id), [
          'to-a',
          'edit',
        ]);
        await listed(store, theyDeleted);
        final judged = (await syncOf(store)).views;
        expect(judged['to-a']!.state, const NeedsUser(ChangedUnseen()));
        expect(judged['edit']!.holds, [
          const BehindEntry('to-a', Dependency.sameRow),
        ]);
      },
    );

    test(
      'B: for lineup groups, my landed delete lets go the group edit on '
      'the deleted page and leaves the edit of a group on another page',
      () async {
        final base = strategyRows(
          elements: initialRows().elements.toList(),
          lineupGroups: [
            bornIn(lineupGroup('g1', pageId: 'page-b'), fixtureLife)
                as LineupGroupRow,
            bornIn(lineupGroup('g2'), fixtureLife) as LineupGroupRow,
          ],
        );
        final deleted = withOp(base, pageDelete('their-drop', 'page-b'));
        LineupGroupPatchOp edited(String opId, String group) =>
            LineupGroupPatchOp(
              opId: opId,
              lineupPublicId: group,
              expectedLineupRevision: 1,
              payload: lineupPayload(group, notes: 'edited'),
            );
        final store = await openCloudStore(MemoryEngine(MemoryStorage()));
        await addCloud(store, base);
        await commit(store, edited('edit-b', 'g1'));
        await commit(store, pageDelete('drop', 'page-b'));
        await commit(store, edited('edit-a', 'g2'));
        await listed(store, deleted);
        expect(await sendable(store), ['drop', 'edit-a']);
        final effects = await answerOnly(store, [
          'drop',
        ], Server()..rows = deleted);
        expect(
          effects,
          contains(const OpRemoved('edit-b', LetGoWithItsPage('drop'))),
        );
        expect((await syncOf(store)).queue.entries.map((entry) => entry.id), [
          'edit-a',
        ]);
      },
    );

    test('B, D: an edit in place on the deleted page, naming it, whose item '
        'a teammate moved off it first is held, never sent, and goes with '
        'my delete of the page, since the server refuses it for the page it '
        'names', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      await commit(
        store,
        movePatch(
          'edit',
          elementId: 'e3',
          pageId: 'page-b',
          merge: FieldMerge(fields: ['position']),
        ),
      );
      await commit(store, pageDelete('drop', 'page-b'));
      final moved = withOp(
        initialRows(),
        ElementPatchOp(
          opId: 'their-move',
          elementPublicId: 'e3',
          expectedElementRevision: 1,
          pagePublicId: 'page-a',
          payload: (initialRows().element('e3')! as LiveElement).payload,
          sortIndex: 5,
        ),
      );
      final server = Server()
        ..rows = withOp(
          moved,
          pageDelete('their-drop', 'page-b', expected: moved.strategy.revision),
        );
      await listed(store, server.rows);
      expect((await viewOf(store, 'edit')).holds, [
        const PageInTrash('page-b'),
      ]);
      expect(await sendable(store), ['drop']);
      expect(
        applyOp(server.rows, pendingIn(await syncOf(store), 'edit').op),
        isA<OpRefused>().having(
          (refused) => refused.refusal,
          'refusal',
          const Failed(FailureCode.pageDeleted),
        ),
      );
      final effects = await answerOnly(store, ['drop'], server);
      expect(
        effects.whereType<OpRemoved>().map((effect) => effect.opId),
        unorderedEquals(['edit', 'drop']),
      );
      expect(
        effects,
        contains(const OpRemoved('edit', LetGoWithItsPage('drop'))),
      );
      expect(server.rows.element('e3')!.pagePublicId, 'page-a');
      expect((await syncOf(store)).queue.entries, isEmpty);
    });

    test('D: a refused edit whose item was confirmed on a page later purged '
        'is not left waiting with no read owed', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      await commit(store, movePatch('edit', elementId: 'e1', x: 50));
      final onB = withOp(
        initialRows(),
        ElementPatchOp(
          opId: 'their-move',
          elementPublicId: 'e1',
          expectedElementRevision: 1,
          pagePublicId: 'page-b',
          payload: (initialRows().element('e1')! as LiveElement).payload,
          sortIndex: 5,
        ),
      );
      final server = Server()
        ..rows = withOp(
          onB,
          pageDelete('their-drop', 'page-b', expected: onB.strategy.revision),
        );
      await answerFrom(store, server);
      await listed(store, server.rows);
      await recordAll(store, [
        await arrivalIn(store, pageReadOf(server.rows, 'page-b')),
      ]);
      final purged = withoutPage(server.rows, 'page-b');
      await listed(store, purged);
      final view = (await syncOf(store)).views.values.single;
      expect(view.sendable || view.state is NeedsUser, isTrue, reason: '$view');
    });

    test('C: a list at the same result order as the one already taken still '
        'issues the refused change again', () async {
      final store = await editedBeforeTheyDeleted([
        movePatch('mine', elementId: 'e3', pageId: 'page-b'),
      ]);
      final server = Server()..rows = theyDeleted;
      final sent = await claimAll(store);
      final refused = server.apply(clientId, sent.ops.single);
      final answeredAt = tick();
      final point = tick();
      await listedAt(store, theyRestored, point);
      await recordAll(store, [
        OpAnswered(sent.attempt, refused, point: answeredAt),
      ]);
      expect(
        (await viewOf(store, 'mine')).holds,
        contains(const RefusedAsPageDeleted()),
      );
      final effects = effectsOf(
        await recordAll(store, [
          BaseArrived(
            headerReadOf(theyRestored),
            session: (await syncOf(store)).queue.session.number,
            point: point,
          ),
        ]),
      );
      expect(
        effects,
        contains(OpRemoved('mine', SentAgainAs(sentAgainId('mine')))),
      );
    });

    group('E: issued again is a stored fact', () {
      Future<LibraryStore> issuedAgain(MemoryStorage storage) async {
        final store = await openCloudStore(MemoryEngine(storage));
        await addCloud(store, initialRows());
        await commit(
          store,
          movePatch('mine', elementId: 'e3', pageId: 'page-b'),
        );
        await answerFrom(store, Server()..rows = theyDeleted);
        await listed(store, theyRestored);
        return store;
      }

      test('it survives a fold and a restart', () async {
        final storage = MemoryStorage();
        var store = await openCloudStore(MemoryEngine(storage));
        await addCloud(store, initialRows());
        final fields = FieldMerge(fields: ['position']);
        await commit(store, movePatch('mine', elementId: 'e3', merge: fields));
        await answerFrom(store, Server()..rows = theyDeleted);
        await listed(store, theyRestored);
        expect(
          pendingIn(await syncOf(store), sentAgainId('mine')).issuedAgainAfter,
          'mine',
        );
        await commit(
          store,
          movePatch('more', elementId: 'e3', x: 90, expected: 2, merge: fields),
        );
        final entries = (await syncOf(store)).queue.entries;
        expect(entries.map((entry) => entry.id), ['more']);
        expect((entries.single as PendingOp).issuedAgainAfter, 'mine');
        await store.close();
        store = await openCloudStore(MemoryEngine(storage));
        expect(pendingIn(await syncOf(store), 'more').issuedAgainAfter, 'mine');
      });

      test('keep mine clears it, so the change can be issued again once more '
          'if it is refused the same way', () async {
        final store = await issuedAgain(MemoryStorage());
        final again = sentAgainId('mine');
        final server = Server()..rows = theyDeleted;
        await answerFrom(store, server);
        await listed(store, theyRestored);
        expect((await viewOf(store, again)).state, isA<NeedsUser>());
        final replacement = movePatch(
          'kept',
          elementId: 'e3',
          pageId: 'page-b',
        );
        await recordAll(store, [
          UserKeptMine(again, replacement, authored: const AuthoredNoRow()),
        ]);
        expect(pendingIn(await syncOf(store), 'kept').issuedAgainAfter, isNull);
        await answerFrom(store, Server()..rows = theyDeleted);
        await listed(store, theyRestored);
        expect(
          pendingIn(await syncOf(store), sentAgainId('kept')).issuedAgainAfter,
          'kept',
        );
      });

      test('an op never issued again does not read as issued again, whatever '
          'its id, and a taken id sends the change to the user', () async {
        final store = await editedBeforeTheyDeleted([
          movePatch('x~again', elementId: 'e3', pageId: 'page-b'),
        ]);
        await answerFrom(store, Server()..rows = theyDeleted);
        await listed(store, theyRestored);
        expect(
          pendingIn(
            await syncOf(store),
            sentAgainId('x~again'),
          ).issuedAgainAfter,
          'x~again',
        );
        final taken = await editedBeforeTheyDeleted([
          movePatch('y', elementId: 'e3', pageId: 'page-b'),
          movePatch('y~again', elementId: 'e1', x: 40),
        ]);
        final server = Server()..rows = theyDeleted;
        await answerOnly(taken, ['y'], server);
        await listed(taken, theyRestored);
        expect((await viewOf(taken, 'y')).state, isA<NeedsUser>());
      });

      test('a record written without the fact reads as not issued again', () {
        const recorded = {
          'version': 1,
          'kind': 'op',
          'op': {
            'opId': 'drop',
            'type': 'page.delete',
            'pagePublicId': 'page-b',
            'expectedStrategyRevision': 1,
          },
          'scope': {'page': 'page-b'},
          'authored': {'revision': 1, 'life': fixtureLife, 'digest': 'd'},
          'authoredIn': 2,
          'authoredAt': 1795737600000,
          'retriedAfter': 0,
          'work': 'op',
          'refusal': null,
        };
        expect(
          decodeEntry(3, recorded, sendable: true),
          isA<Read<QueueEntry>>().having(
            (read) => (read.value as PendingOp).issuedAgainAfter,
            'issuedAgainAfter',
            isNull,
          ),
        );
      });
    });

    test('G: a change issued again keeps its age, so near the end of the '
        'window it comes back as written long ago', () async {
      var clock = fixedClock();
      final store = await openCloudStore(
        MemoryEngine(MemoryStorage()),
        clock: () => clock,
      );
      await addCloud(store, initialRows());
      await commit(store, movePatch('mine', elementId: 'e3', pageId: 'page-b'));
      await answerFrom(store, Server()..rows = theyDeleted);
      clock = clock.add(resendWindow);
      await listed(store, theyRestored);
      await recordAll(store, const []);
      expect(
        (await viewOf(store, sentAgainId('mine'))).state,
        const NeedsUser(WrittenLongAgo()),
      );
    });
  });
}

Object? entryRecordOf(CloudStrategy cloud, String id) =>
    entryToJson(cloud.queue.entry(id)!);
