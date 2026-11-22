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
    await store.commit(
      strategyId,
      movePatch(
        'drag',
        elementId: 'e0-0',
        x: 40,
        merge: FieldMerge(fields: ['position']),
      ),
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
}
