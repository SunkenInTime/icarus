import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_budget_test.dart' show strategyWith;
import 'store_support.dart';
import 'support.dart';

const _itemsAPage = 30;

Future<Contents> _stored(int pages) async {
  final storage = MemoryStorage();
  final store = await openStore(MemoryEngine(storage));
  savedValue(
    await store.editLibrary([
      AddStrategy(strategyWith('s', items: _itemsAPage, pages: pages)),
    ]),
  );
  await store.close();
  return storage.contents;
}

typedef _PageCost = ({
  int keyListings,
  int pointReads,
  int entryListings,
  int rowsListed,
  int rowsCounted,
});

void main() {
  for (final pages in [1, 20, 100]) {
    test('reading every page of a $pages-page strategy costs each page one '
        'listing of its own $_itemsAPage rows and counts only those rows for '
        'the summary, however many pages are already loaded', () async {
      final (engine, counts) = counting(
        MemoryEngine(MemoryStorage(editable(await _stored(pages)))),
      );
      final store = await openStore(engine);
      counts.reset();
      final content = strategyOf(await store.readStrategy('s'));
      expect(counts.keyListings, hasLength(1), reason: 'the header lists');
      var counted = store.rowsCountedFor('s');

      final costs = <_PageCost>[];
      for (final page in content.pages) {
        counts.reset();
        expect(
          pageOf(await store.readPage('s', page.publicId)).elements,
          hasLength(_itemsAPage),
        );
        costs.add((
          keyListings: counts.keyListings.length,
          pointReads: counts.reads.length,
          entryListings: counts.entryListings.length,
          rowsListed: counts.listedEntries.length,
          rowsCounted: store.rowsCountedFor('s') - counted,
        ));
        counted = store.rowsCountedFor('s');
      }

      expect(costs, [
        for (var i = 0; i < pages; i++)
          (
            keyListings: 0,
            pointReads: 0,
            entryListings: 1,
            rowsListed: _itemsAPage,
            rowsCounted: _itemsAPage,
          ),
      ]);
      await store.close();
    });
  }

  test('a page that holds only deleted items is counted once when it is read, '
      'like any other page', () async {
    const pages = 20;
    final pageIds = [for (var i = 0; i < pages; i++) 's-page-$i'];
    final storage = MemoryStorage();
    final written = await openStore(MemoryEngine(storage));
    savedValue(
      await written.editLibrary([
        AddStrategy(
          StrategyRowSet(
            strategy: strategyRow(publicId: 's', name: 's', mapData: 'bind'),
            pages: [
              for (final (index, pageId) in pageIds.indexed)
                LivePage(
                  publicId: pageId,
                  strategyPublicId: 's',
                  name: 'Page ${index + 1}',
                  sortIndex: index,
                  isAttack: true,
                  revision: 1,
                ),
            ],
            settings: [for (final pageId in pageIds) settings(pageId)],
            elements: [
              for (final pageId in pageIds)
                for (var i = 0; i < _itemsAPage; i++)
                  deletedElement('$pageId-gone-$i', pageId: pageId),
            ],
          ),
        ),
      ]),
    );
    await written.close();

    final store = await openStore(
      MemoryEngine(MemoryStorage(editable(storage.contents))),
    );
    expect(listOf(store).strategies.single.tallies, isEmpty);
    final content = strategyOf(await store.readStrategy('s'));
    var counted = store.rowsCountedFor('s');
    final countedByPage = <int>[];
    for (final page in content.pages) {
      pageOf(await store.readPage('s', page.publicId));
      countedByPage.add(store.rowsCountedFor('s') - counted);
      counted = store.rowsCountedFor('s');
    }

    expect(countedByPage, [for (var i = 0; i < pages; i++) _itemsAPage]);
    expect(listOf(store).strategies.single.tallies, isEmpty);
    await store.close();
  });

  test(
    'reading every page leaves the summary as it was and nothing to save',
    () async {
      final disk = await _stored(20);
      final storage = MemoryStorage(editable(disk));
      final store = await openStore(MemoryEngine(storage));
      final before = listOf(store).strategies.single;

      final content = strategyOf(await store.readStrategy('s'));
      for (final page in content.pages) {
        pageOf(await store.readPage('s', page.publicId));
      }

      expect(listOf(store).strategies.single, before);
      await store.close();
      expect(sameContents(storage.contents, disk), isTrue);
    },
  );

  test('a page whose stored count is wrong is counted again when it is read, '
      'and the summary is put right', () async {
    final disk = editable(await _stored(3));
    final right =
        jsonDecode(disk['library']![summaryName('s')]!) as Map<String, Object?>;
    final wrong = jsonDecode(jsonEncode(right)) as Map<String, Object?>;
    final tallies = wrong['tallies']! as Map<String, Object?>;
    (tallies['s-page-1']! as Map<String, Object?>)['items'] = 999;
    disk['library']![summaryName('s')] = jsonEncode(wrong);
    final store = await openStore(MemoryEngine(MemoryStorage(disk)));
    expect(listOf(store).strategies.single.tallies['s-page-1']?.items, 999);

    final content = strategyOf(await store.readStrategy('s'));
    pageOf(await store.readPage('s', content.pages[0].publicId));
    expect(
      listOf(store).strategies.single.tallies['s-page-1']?.items,
      999,
      reason: 'reading another page leaves this page\'s count alone',
    );
    pageOf(await store.readPage('s', content.pages[1].publicId));

    expect(
      listOf(store).strategies.single.tallies['s-page-1']?.items,
      _itemsAPage,
    );
    await store.close();
  });
}
