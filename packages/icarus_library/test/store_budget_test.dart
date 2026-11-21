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

void main() {
  for (final (strategies, items) in [(5, 10), (60, 300)]) {
    group('With $strategies strategies of $items items a page', () {
      late Contents disk;

      setUpAll(() async {
        disk = (await library(strategies: strategies, items: items)).contents;
      });

      test(
        'moving one item is one commit of four keys, reading nothing',
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
              ('library', 'last-save'),
            ]),
          );
          expect(counts.deleted, isEmpty);
          expect(counts.calls, 1);
          expect(counts.reads, isEmpty);
          expect(counts.listings, isEmpty);
        },
      );

      test(
        'moving one item on a page not yet open lists and reads only that page',
        () async {
          final (store, counts) = await openedOn(disk);
          strategyOf(await store.readStrategy('s1'));
          counts.reset();
          savedValue(await store.commit('s1', moveOne('s1')));
          expect(counts.keyWrites, 4);
          expect(counts.calls, 1);
          expect(counts.listings, [
            (strategyArea('s1'), 'content/${digestOf('s1-page-1')}/'),
          ]);
          expect(counts.listed, items);
          expect(counts.reads, hasLength(items));
        },
      );

      test('opening a page lists and reads only that page', () async {
        final (store, counts) = await openedOn(disk);
        strategyOf(await store.readStrategy('s2'));
        counts.reset();
        final page = pageOf(await store.readPage('s2', 's2-page-2'));
        expect(page.elements, hasLength(items));
        expect(counts.listings, [
          (strategyArea('s2'), 'content/${digestOf('s2-page-2')}/'),
        ]);
        expect(counts.listed, items);
        expect(
          counts.reads.map((read) => read.$2),
          everyElement(startsWith('content/${digestOf('s2-page-2')}/')),
        );
      });

      test(
        'opening a strategy reads its row, pages and settings, and lists its keys',
        () async {
          final (store, counts) = await openedOn(disk);
          counts.reset();
          strategyOf(await store.readStrategy('s3'));
          expect(counts.listings, [
            (strategyArea('s3'), ''),
            (strategyArea('s3'), 'page/'),
            (strategyArea('s3'), 'settings/'),
          ]);
          expect(counts.reads.map((read) => read.$2), [
            'strategy',
            ...[for (var i = 0; i < 3; i++) pageName('s3-page-$i')]..sort(),
            ...[for (var i = 0; i < 3; i++) settingsName('s3-page-$i')]..sort(),
          ]);
          expect(counts.listed, (1 + 3 + 3 + 3 * items) + 3 + 3);
        },
      );

      test('opening the library list reads only summaries', () async {
        final (store, counts) = await openedOn(disk);
        expect(listOf(store).strategies, hasLength(strategies));
        expect(counts.listings, [('library', '')]);
        expect(counts.reads.toSet(), {
          ('library', 'last-save'),
          for (var i = 0; i < strategies; i++) ('library', summaryName('s$i')),
        });
        expect(counts.calls, 0);
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
      expect(counts.reads, [
        ('library', 'last-save'),
        ('library', 'last-save'),
        ('library', summaryName('big')),
      ]);
      counts.reset();
      final content = strategyOf(await store.readStrategy('big'));
      expect(content.pages, hasLength(20));
      expect(counts.reads, hasLength(1 + 20 + 20));
      expect(counts.listed, (1 + 20 + 20 + 20 * 300) + 20 + 20);
      counts.reset();
      pageOf(await store.readPage('big', 'big-page-7'));
      expect(counts.listings, [
        (strategyArea('big'), 'content/${digestOf('big-page-7')}/'),
      ]);
      expect(counts.listed, 300);
      expect(counts.reads, hasLength(300));
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
      expect(counts.keyWrites, 4);
      expect(counts.calls, 1);
      expect(counts.reads, isEmpty);
      expect(counts.listings, isEmpty);
    });
  });
}
