import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

StrategyRowSet strategyWith(String id, {required int items, int pages = 3}) {
  final pageIds = [for (var i = 0; i < pages; i++) '$id-page-$i'];
  return StrategyRowSet(
    strategy: strategyRow(publicId: id, name: id, mapData: 'bind'),
    pages: [
      for (final (index, pageId) in pageIds.indexed)
        LivePage(
          publicId: pageId,
          strategyPublicId: id,
          name: 'Page ${index + 1}',
          sortIndex: index,
          isAttack: true,
          revision: 1,
        ),
    ],
    settings: [for (final pageId in pageIds) settings(pageId)],
    elements: [
      for (final pageId in pageIds)
        for (var i = 0; i < items; i++)
          i.isEven
              ? agent('$pageId-agent-$i', pageId: pageId, sortIndex: i)
              : drawing('$pageId-drawing-$i', pageId: pageId, points: 200),
    ],
  );
}

Future<MemoryStorage> library({
  required int strategies,
  required int items,
}) async {
  final storage = MemoryStorage();
  final store = await openStore(MemoryEngine(storage));
  savedValue(
    await store.editLibrary([
      for (var i = 0; i < strategies; i++)
        AddStrategy(strategyWith('s$i', items: i < 4 ? items : 2)),
    ]),
  );
  await store.close();
  return storage;
}

ElementPatchOp moveOne(String strategy) => ElementPatchOp(
  opId: 'move-$strategy',
  elementPublicId: '$strategy-page-1-agent-0',
  expectedElementRevision: 1,
  payload: agentPayload('$strategy-page-1-agent-0', {
    'type': 'jett',
    'position': {'dx': 99, 'dy': 98},
  }),
  merge: FieldMerge(fields: ['position']),
);

Future<(LibraryStore, Counts)> openedOn(Contents disk) async {
  final (engine, counts) = counting(MemoryEngine(MemoryStorage(disk)));
  return (await openStore(engine), counts);
}

void expectNoReads(Counts counts) {
  expect(counts.reads, isEmpty, reason: 'point reads');
  expect(counts.keyListings, isEmpty, reason: 'key listings');
  expect(counts.entryListings, isEmpty, reason: 'entry listings');
}

void main() {
  for (final (strategies, items) in [(5, 10), (60, 300)]) {
    group('With $strategies strategies of $items items a page', () {
      late Contents disk;

      setUpAll(() async {
        disk = (await library(strategies: strategies, items: items)).contents;
      });

      test(
        'moving one item is one commit of three names, reading nothing',
        () async {
          final (store, counts) = await openedOn(disk);
          pageOf(await store.readPage('s1', 's1-page-1'));
          counts.reset();
          savedValue(await store.commit('s1', moveOne('s1')));
          expect(
            counts.written,
            unorderedEquals([
              (
                strategyArea('s1'),
                elementName('s1-page-1', 's1-page-1-agent-0'),
              ),
              (strategyArea('s1'), 'strategy'),
              ('library', summaryName('s1')),
            ]),
          );
          expect(counts.deleted, isEmpty);
          expect(counts.commits, 1);
          expectNoReads(counts);
        },
      );

      test(
        'moving one item on a page not yet open is one entries call for that page',
        () async {
          final (store, counts) = await openedOn(disk);
          strategyOf(await store.readStrategy('s1'));
          counts.reset();
          savedValue(await store.commit('s1', moveOne('s1')));
          expect(counts.keyWrites, 3);
          expect(counts.commits, 1);
          expect(counts.reads, isEmpty);
          expect(counts.keyListings, isEmpty);
          expect(counts.entryListings, [
            (strategyArea('s1'), 'content/${digestOf('s1-page-1')}/'),
          ]);
          expect(counts.listedEntries, hasLength(items));
        },
      );

      test('opening a page is one entries call for that page', () async {
        final (store, counts) = await openedOn(disk);
        strategyOf(await store.readStrategy('s2'));
        counts.reset();
        final page = pageOf(await store.readPage('s2', 's2-page-2'));
        expect(page.elements, hasLength(items));
        expect(counts.reads, isEmpty);
        expect(counts.keyListings, isEmpty);
        expect(counts.entryListings, [
          (strategyArea('s2'), 'content/${digestOf('s2-page-2')}/'),
        ]);
        expect(counts.listedEntries, hasLength(items));
        expect(counts.commits, 0);
      });

      test(
        'opening a strategy is one read, one key listing and two entries calls',
        () async {
          final (store, counts) = await openedOn(disk);
          counts.reset();
          strategyOf(await store.readStrategy('s3'));
          expect(counts.reads, [(strategyArea('s3'), 'strategy')]);
          expect(counts.keyListings, [(strategyArea('s3'), '')]);
          expect(counts.listedKeys, 1 + 3 + 3 + 3 * items);
          expect(counts.entryListings, [
            (strategyArea('s3'), 'page/'),
            (strategyArea('s3'), 'settings/'),
          ]);
          expect(counts.listedEntries, hasLength(3 + 3));
        },
      );

      test('opening the library list is one entries call', () async {
        final (store, counts) = await openedOn(disk);
        expect(listOf(store).strategies, hasLength(strategies));
        expect(counts.reads, isEmpty);
        expect(counts.keyListings, isEmpty);
        expect(counts.entryListings, [('library', '')]);
        expect(
          counts.listedEntries,
          unorderedEquals([
            for (var i = 0; i < strategies; i++)
              ('library', summaryName('s$i')),
          ]),
        );
        expect(counts.commits, 0);
      });
    });
  }

  group('A strategy of 20 pages with 300 items each', () {
    late Contents disk;

    setUpAll(() async {
      final storage = MemoryStorage();
      final store = await openStore(MemoryEngine(storage));
      savedValue(
        await store.editLibrary([
          AddStrategy(strategyWith('big', items: 300, pages: 20)),
        ]),
      );
      await store.close();
      disk = storage.contents;
    });

    test('a cold open, a cold page read and one warm move', () async {
      final (store, counts) = await openedOn(disk);
      expect(counts.reads, isEmpty);
      expect(counts.entryListings, [('library', '')]);
      expect(counts.listedEntries, [('library', summaryName('big'))]);
      counts.reset();
      final content = strategyOf(await store.readStrategy('big'));
      expect(content.pages, hasLength(20));
      expect(counts.reads, hasLength(1));
      expect(counts.keyListings, hasLength(1));
      expect(counts.listedKeys, 1 + 20 + 20 + 20 * 300);
      expect(counts.entryListings, hasLength(2));
      expect(counts.listedEntries, hasLength(20 + 20));
      counts.reset();
      pageOf(await store.readPage('big', 'big-page-7'));
      expect(counts.reads, isEmpty);
      expect(counts.keyListings, isEmpty);
      expect(counts.entryListings, [
        (strategyArea('big'), 'content/${digestOf('big-page-7')}/'),
      ]);
      expect(counts.listedEntries, hasLength(300));
      counts.reset();
      savedValue(
        await store.commit(
          'big',
          ElementPatchOp(
            opId: 'warm-move',
            elementPublicId: 'big-page-7-agent-0',
            expectedElementRevision: 1,
            payload: agentPayload('big-page-7-agent-0', {
              'type': 'jett',
              'position': {'dx': 1, 'dy': 2},
            }),
            merge: FieldMerge(fields: ['position']),
          ),
        ),
      );
      expect(counts.keyWrites, 3);
      expect(counts.commits, 1);
      expectNoReads(counts);
    });
  });
}
