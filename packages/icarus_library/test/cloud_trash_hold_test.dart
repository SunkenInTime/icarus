import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/codec.dart' show entryToJson;
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

Object? entryRecordOf(CloudStrategy cloud, String id) =>
    entryToJson(cloud.queue.entry(id)!);
