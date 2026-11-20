import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

StrategyRowSet strategyWith(String id, {required int items, int pages = 3}) {
  final pageIds = [for (var i = 0; i < pages; i++) '$id-page-$i'];
  return StrategyRowSet(
    strategy: StrategyRow(publicId: id, name: id, mapData: 'bind', revision: 1),
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
    settings: [
      for (final pageId in pageIds)
        PageSettingsRow(
          pagePublicId: pageId,
          settings: defaultSettings,
          revision: 1,
        ),
    ],
    elements: [
      for (final pageId in pageIds)
        for (var i = 0; i < items; i++)
          i.isEven
              ? LiveElement(
                  publicId: '$pageId-agent-$i',
                  pagePublicId: pageId,
                  payload: agent('$pageId-agent-$i').payload,
                  sortIndex: i,
                  revision: 1,
                )
              : drawing('$pageId-drawing-$i', pageId: pageId, points: 200),
    ],
  );
}

Future<MemoryEngine> library({
  required int strategies,
  required int items,
}) async {
  final engine = MemoryEngine();
  final store = await openStore(engine);
  savedValue(
    await store.editLibrary([
      for (var i = 0; i < strategies; i++)
        AddStrategy(
          strategyWith('s$i', items: i < 4 ? items : 2),
          createdAt: createdAt,
          updatedAt: createdAt,
        ),
    ]),
  );
  return engine;
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
      late MemoryEngine disk;

      setUpAll(() async {
        disk = await library(strategies: strategies, items: items);
      });

      test('moving one item writes four keys and reads nothing', () async {
        final counting = CountingEngine(MemoryEngine(disk.contents));
        final store = await openStore(counting);
        pageOf(await store.readPage('s1', 's1-page-1'));
        counting.reset();
        savedValue(await store.commit('s1', moveOne('s1')));
        expect(counting.written, [
          ('journal', 'edit'),
          ('strategy/s1', 'content/s1-page-1/element/s1-page-1-agent-0'),
          ('library', 'summary/s1'),
        ]);
        expect(counting.deleted, [('journal', 'edit')]);
        expect(counting.reads, isEmpty);
        expect(counting.listings, isEmpty);
      });

      test(
        'moving one item on a page not yet open reads only that page',
        () async {
          final counting = CountingEngine(MemoryEngine(disk.contents));
          final store = await openStore(counting);
          strategyOf(await store.readStrategy('s1'));
          counting.reset();
          savedValue(await store.commit('s1', moveOne('s1')));
          expect(counting.keyWrites, 4);
          expect(
            counting.reads.map((read) => read.$2),
            everyElement(startsWith('content/s1-page-1/')),
          );
          expect(counting.reads, hasLength(items));
        },
      );

      test('opening a page reads only that page\'s keys', () async {
        final counting = CountingEngine(MemoryEngine(disk.contents));
        final store = await openStore(counting);
        strategyOf(await store.readStrategy('s2'));
        counting.reset();
        final page = pageOf(await store.readPage('s2', 's2-page-2'));
        expect(page.elements, hasLength(items));
        expect(counting.listings, [('strategy/s2', 'content/s2-page-2/')]);
        expect(counting.reads, hasLength(items));
        expect(
          counting.reads,
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
          final counting = CountingEngine(MemoryEngine(disk.contents));
          final store = await openStore(counting);
          counting.reset();
          strategyOf(await store.readStrategy('s3'));
          expect(
            counting.reads.map((read) => read.$2),
            everyElement(
              anyOf('strategy', startsWith('page/'), startsWith('settings/')),
            ),
          );
          expect(counting.reads, hasLength(1 + 3 + 3));
        },
      );

      test('opening the library list reads only summaries', () async {
        final counting = CountingEngine(MemoryEngine(disk.contents));
        final store = await openStore(counting);
        expect(store.library.strategies, hasLength(strategies));
        expect(counting.reads.toSet(), {
          ('journal', 'edit'),
          for (var i = 0; i < strategies; i++) ('library', 'summary/s$i'),
        });
        expect(counting.listings, [
          ('library', 'summary/'),
          ('library', 'folder/'),
        ]);
        expect(counting.keyWrites, 0);
      });
    });
  }
}
