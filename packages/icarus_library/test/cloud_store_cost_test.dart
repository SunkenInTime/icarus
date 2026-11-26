import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/store/store.dart' show storeWork;
import 'package:test/test.dart';

import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

StrategyRowSet pagesOfThirty(int pages) => strategyRows(
  pages: [for (var p = 0; p < pages; p++) page('p$p', sortIndex: p)],
  elements: [
    for (var p = 0; p < pages; p++)
      for (var e = 0; e < 30; e++)
        element('e$p-$e', pageId: 'p$p', sortIndex: e),
  ],
);

Future<({int rows, int groups})> oneFieldEdit(int pages) async {
  final store = await openCloudStore(MemoryEngine(MemoryStorage()));
  await addCloud(store, pagesOfThirty(pages));
  await store.readStrategy(strategyId);
  for (var p = 0; p < pages; p++) {
    await store.readPage(strategyId, 'p$p');
  }
  storeWork.reset();
  savedValue(
    await store.commitAs(
      testAccount,
      strategyId,
      movePatch(
        'drag',
        elementId: 'e0-0',
        x: 40,
        merge: FieldMerge(fields: ['position']),
      ),
      seen: await seenIn(store),
    ),
  );
  final work = (
    rows: storeWork.rowsDrawn,
    groups: storeWork.resultGroupsEncoded,
  );
  await store.close();
  return work;
}

void main() {
  test('one queued field edit does the same work at 10 pages and at 100, '
      'with every page loaded', () async {
    final small = await oneFieldEdit(10);
    final large = await oneFieldEdit(100);
    expect(large, small);
    expect(small.groups, 0);
    expect(small.rows, lessThanOrEqualTo(60));
  });

  test('removing strategies releases their session records', () async {
    final store = await openCloudStore(MemoryEngine(MemoryStorage()));
    for (var i = 0; i < 24; i++) {
      final id = 'strategy-$i';
      savedValue(
        await store.addCloudStrategy(
          testAccount,
          stamped(
            HeaderRead(
              strategy: strategyRow(publicId: id),
              pages: [
                LivePage(
                  publicId: 'page-a',
                  strategyPublicId: id,
                  name: 'Page 1',
                  sortIndex: 0,
                  isAttack: true,
                  revision: 1,
                  unknownFields: jsonObject({'createdAt': fixtureLife}),
                ),
              ],
              settings: [settings('page-a')],
            ),
          ),
          stampedPages(const []),
        ),
      );
      expect(await store.unload(id), isA<Unloaded>());
    }
    expect(storeWork.sessionRecords(), 24);
    savedValue(
      await store.editLibrary([
        for (var i = 0; i < 24; i++) RemoveStrategy('strategy-$i'),
      ]),
    );
    expect(listOf(store).strategies, isEmpty);
    expect(storeWork.sessionRecords(), 0);
  });
}
