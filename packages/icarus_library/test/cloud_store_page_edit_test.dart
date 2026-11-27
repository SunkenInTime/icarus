import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/page_copy.dart' show pageCopyRoot;
import 'package:test/test.dart';

import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

SeenPage drawnAs(PageContent page) => seenPageOf(
  page.page,
  contentSeenOf([
    if (page.settings case SettingsStored(:final row)) row,
    ...page.elements,
    ...page.lineupGroups,
  ]),
);

Future<void> deleteAsSeen(
  LibraryStore store,
  String pageId,
  SeenPage seen,
) async => savedValue(
  await store.commitAllAs(
    testAccount,
    strategyId,
    [pageDelete('drop', pageId)],
    seen: await seenIn(store),
    made: MadeChecked(pagesAsSeen: {pageId: seen}),
  ),
);

Future<EntryView> viewOf(LibraryStore store, String id) async =>
    (await syncOf(store)).views[id]!;

SeenPage storedSeenOf(CloudStrategy cloud, String id) =>
    switch (cloud.queue.entry(id)) {
      PendingOp(work: CheckedDelete(:final seen)) => seen,
      final other => fail('$id is not a checked delete: $other'),
    };

UnreadableElement unreadableElement(
  String id,
  Object? stored,
  UnreadableReason reason,
) => UnreadableElement(
  publicId: id,
  pagePublicId: 'page-a',
  stored: stored,
  problem: 'not drawn here',
  reason: reason,
);

Map<String, Object?> storedWith(String id, Map<String, Object?> payload) => {
  ...element(id).toJson(),
  'payload': payload,
};

Future<(LibraryStore, MemoryStorage)> cloudWith({
  List<ElementRow> elements = const [],
  List<LineupGroupRow> lineupGroups = const [],
  PageRow? source,
}) async {
  final storage = MemoryStorage();
  final store = await openCloudStore(MemoryEngine(storage));
  final rows = initialRows();
  final page = source ?? rows.page('page-a')!;
  savedValue(
    await store.addCloudStrategy(
      testAccount,
      stamped(
        HeaderRead(
          strategy: rows.strategy,
          pages: [page, rows.page('page-b')!],
          settings: rows.settings.toList(),
        ),
      ),
      stampedPages([
        PageRead(
          page: page,
          elements: [...rows.elementsOn('page-a'), ...elements],
          lineupGroups: lineupGroups,
        ),
        pageReadOf(rows, 'page-b') as PageRead,
      ]),
    ),
  );
  return (store, storage);
}

Future<BatchResult> copyPageA(LibraryStore store) async => store.commitAllAs(
  testAccount,
  strategyId,
  [pageAdd('copy', 'page-c', copyFrom: 'page-a')],
  seen: await seenIn(store),
);

void main() {
  final theirs = withOp(
    initialRows(),
    elementAdd('t', elementId: 'theirs', pageId: 'page-a'),
  );

  group('a page delete records the page as the editor drew it', () {
    test('a teammate\'s element the editor never drew holds the delete once '
        'the server\'s page has it', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      final drawn = pageOf(await store.readPage(strategyId, 'page-a'));
      await readServer(store, theirs, pages: ['page-a']);
      await deleteAsSeen(store, 'page-a', drawnAs(drawn));
      expect(
        (await viewOf(store, 'drop')).state,
        const NeedsUser(DeleteHeld(HeldDeleteCause.pageChanged)),
      );
    });

    test('the delete goes when the server\'s page is the page the editor '
        'drew, though the store held a teammate\'s element since', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      final drawn = pageOf(await store.readPage(strategyId, 'page-a'));
      await readServer(store, theirs, pages: ['page-a']);
      await deleteAsSeen(store, 'page-a', drawnAs(drawn));
      await readServer(
        store,
        withOp(
          theirs,
          elementDelete('t2', elementId: 'theirs', pageId: 'page-a'),
        ),
        pages: ['page-a'],
      );
      expect((await viewOf(store, 'drop')).sendable, isTrue);
    });

    test('a page whose content the editor never read holds the delete as '
        'never read', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      final drawn = pageOf(await store.readPage(strategyId, 'page-a'));
      await deleteAsSeen(
        store,
        'page-a',
        seenPageOf(drawn.page, const ContentNeverRead()),
      );
      expect(
        (await viewOf(store, 'drop')).state,
        const NeedsUser(DeleteHeld(HeldDeleteCause.contentNeverRead)),
      );
    });

    test('the page as drawn survives a reopen, read or never read', () async {
      for (final content in [true, false]) {
        final storage = MemoryStorage();
        var store = await openCloudStore(MemoryEngine(storage));
        await addCloud(store, initialRows());
        final drawn = pageOf(await store.readPage(strategyId, 'page-a'));
        await readServer(store, theirs, pages: ['page-a']);
        final seen = content
            ? drawnAs(drawn)
            : seenPageOf(drawn.page, const ContentNeverRead());
        await deleteAsSeen(store, 'page-a', seen);
        await store.close();
        store = await openCloudStore(MemoryEngine(storage));
        expect(storedSeenOf(await syncOf(store), 'drop'), seen);
      }
    });
  });
  group('a page copy keeps what this build cannot draw', () {
    final newer = unreadableElement(
      'newer',
      storedWith('newer', {
        'kind': 'agent',
        'payloadVersion': newestElementPayloadVersion + 1,
        'data': {'id': 'newer', 'elementType': 'agent', 'hologram': true},
      }),
      const FromNewerBuild(),
    );
    final damaged = unreadableElement('damaged', {
      ...element('damaged').toJson(),
      'revision': 'two',
    }, const Damaged());

    test('an element from a newer build and a damaged element whose payload '
        'reads are copied under new ids', () async {
      final (store, storage) = await cloudWith(elements: [newer, damaged]);
      savedValue(await copyPageA(store));
      final copy = pageOf(await store.readPage(strategyId, 'page-c'));
      final copied = {
        for (final row in copy.elements) pageCopyRoot(row.publicId): row,
      };
      expect(copied.keys, unorderedEquals(['e1', 'e2', 'newer', 'damaged']));
      expect(
        copied['newer'],
        isA<UnreadableElement>()
            .having((row) => row.reason, 'reason', const FromNewerBuild())
            .having((row) => row.pagePublicId, 'page', 'page-c'),
      );
      expect(copied['damaged'], isA<LiveElement>());
      for (final MapEntry(:key, :value) in copied.entries) {
        expect(value.publicId, isNot(key));
      }
      final adds = [
        for (final entry in (await syncOf(store)).queue.entries)
          if (entry case PendingOp(op: final ElementAddOp add)) add,
      ];
      final newerAdd = adds.singleWhere(
        (add) => add.elementPublicId == copied['newer']!.publicId,
      );
      expect(newerAdd.payload.payloadVersion, newestElementPayloadVersion + 1);
      expect(newerAdd.payload.data['id'], newerAdd.elementPublicId);
      expect(newerAdd.payload.data['hologram'], isTrue);
      await store.close();
      final reopened = await openCloudStore(MemoryEngine(storage));
      expect(
        (await syncOf(reopened)).queue.entry(newerAdd.opId),
        isA<PendingOp>().having((entry) => entry.op, 'op', newerAdd),
      );
      expect(sendForm(newerAdd, SendPolicy.live).toJson(), newerAdd.toJson());
    });

    Future<void> expectStopped(
      (LibraryStore, MemoryStorage) cloud,
      CopyStopped reason,
    ) async {
      final (store, storage) = cloud;
      final before = storage.contents;
      expect(
        await copyPageA(store),
        isA<Refused<List<Committed>, CommitRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          reason,
        ),
      );
      expect(sameContents(before, storage.contents), isTrue);
    }

    test(
      'an element of a kind this build does not know stops the copy',
      () async {
        await expectStopped(
          await cloudWith(
            elements: [
              unreadableElement(
                'hologram',
                storedWith('hologram', {
                  'kind': 'hologram',
                  'payloadVersion': 1,
                  'data': <String, Object?>{},
                }),
                const FromNewerBuild(),
              ),
            ],
          ),
          const CopyHasUnsendableElement(
            'page-a',
            'hologram',
            FromNewerBuild(),
          ),
        );
      },
    );

    test(
      'a damaged element whose payload does not read stops the copy',
      () async {
        await expectStopped(
          await cloudWith(
            elements: [
              unreadableElement(
                'broken',
                storedWith('broken', {'kind': 'agent', 'payloadVersion': 1}),
                const Damaged(),
              ),
            ],
          ),
          const CopyHasUnsendableElement('page-a', 'broken', Damaged()),
        );
      },
    );

    test('an unreadable lineup group stops the copy', () async {
      await expectStopped(
        await cloudWith(
          lineupGroups: [
            UnreadableLineupGroup(
              publicId: 'group',
              strategyPublicId: strategyId,
              pagePublicId: 'page-a',
              stored: {
                ...lineupGroup('group').toJson(),
                'createdAt': fixtureLife,
                'payload': {
                  'kind': 'lineups',
                  'payloadVersion': 99,
                  'data': <String, Object?>{},
                },
              },
              problem: 'not drawn here',
            ),
          ],
        ),
        const CopyHasUnreadableLineupGroup('page-a', 'group'),
      );
    });

    test('an unreadable source page stops the copy', () async {
      await expectStopped(
        await cloudWith(
          source: UnreadablePage(
            publicId: 'page-a',
            strategyPublicId: strategyId,
            sortIndex: 0,
            trashed: false,
            stored: {
              ...page('page-a', sortIndex: 0).toJson()! as Map<String, Object?>,
              'name': 7,
            },
            problem: 'not drawn here',
          ),
        ),
        const CopySourceUnreadable('page-a'),
      );
    });

    test('a page whose content was never read stops the copy', () async {
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      savedValue(
        await store.addCloudStrategy(
          testAccount,
          stamped(headerReadOf(initialRows())),
          stampedPages(const []),
        ),
      );
      await expectStopped((store, storage), const CopyNeedsContent('page-a'));
    });
  });
}
