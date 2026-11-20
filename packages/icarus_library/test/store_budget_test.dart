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

void main() {
  for (final (strategies, items) in [(5, 10), (60, 300)]) {
    group('With $strategies strategies of $items items a page', () {
      late Contents disk;

      setUpAll(() async {
        disk = (await library(strategies: strategies, items: items)).contents;
      });

      Future<(LibraryStore, Counts)> opened() async {
        final (engine, counts) = counting(MemoryEngine(MemoryStorage(disk)));
        return (await openStore(engine), counts);
      }

      test(
        'moving one item writes five keys in four calls, reading nothing',
        () async {
          final (store, counts) = await opened();
          pageOf(await store.readPage('s1', 's1-page-1'));
          counts.reset();
          savedValue(await store.commit('s1', moveOne('s1')));
          expect(
            counts.written,
            unorderedEquals([
              ('journal', 'edit'),
              ('strategy/s1', 'content/s1-page-1/element/s1-page-1-agent-0'),
              ('strategy/s1', 'strategy'),
              ('library', 'summary/s1'),
            ]),
          );
          expect(counts.deleted, [('journal', 'edit')]);
          expect(counts.calls, 4);
          expect(counts.reads, isEmpty);
          expect(counts.listings, isEmpty);
        },
      );

      test(
        'moving one item on a page not yet open reads only that page',
        () async {
          final (store, counts) = await opened();
          strategyOf(await store.readStrategy('s1'));
          counts.reset();
          savedValue(await store.commit('s1', moveOne('s1')));
          expect(counts.keyWrites, 5);
          expect(counts.listings, [('strategy/s1', 'content/s1-page-1/')]);
          expect(
            counts.reads.map((read) => read.$2),
            everyElement(startsWith('content/s1-page-1/')),
          );
          expect(counts.reads, hasLength(items));
        },
      );

      test('opening a page lists and reads only that page', () async {
        final (store, counts) = await opened();
        strategyOf(await store.readStrategy('s2'));
        counts.reset();
        final page = pageOf(await store.readPage('s2', 's2-page-2'));
        expect(page.elements, hasLength(items));
        expect(counts.listings, [('strategy/s2', 'content/s2-page-2/')]);
        expect(counts.listed, items);
        expect(counts.reads, hasLength(items));
        expect(
          counts.reads,
          everyElement(
            isA<(String, String)>()
                .having((read) => read.$1, 'area', 'strategy/s2')
                .having(
                  (read) => read.$2,
                  'key',
                  startsWith('content/s2-page-2/'),
                ),
          ),
        );
      });

      test(
        'opening a strategy reads its row, pages and settings only',
        () async {
          final (store, counts) = await opened();
          counts.reset();
          strategyOf(await store.readStrategy('s3'));
          expect(
            counts.reads.map((read) => read.$2),
            everyElement(
              anyOf('strategy', startsWith('page/'), startsWith('settings/')),
            ),
          );
          expect(counts.reads, hasLength(1 + 3 + 3));
          expect(counts.listings, [
            ('strategy/s3', 'page/'),
            ('strategy/s3', 'settings/'),
            ('strategy/s3', 'content/'),
          ]);
          expect(counts.listed, 3 + 3 + 3 * items);
        },
      );

      test('opening the library list reads only summaries', () async {
        final (store, counts) = await opened();
        expect(store.library.strategies, hasLength(strategies));
        expect(counts.reads.toSet(), {
          ('journal', 'edit'),
          for (var i = 0; i < strategies; i++) ('library', 'summary/s$i'),
        });
        expect(counts.listings, [
          ('library', 'summary/'),
          ('library', 'folder/'),
        ]);
        expect(counts.calls, 0);
      });
    });
  }
}
