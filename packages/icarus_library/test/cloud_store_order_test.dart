import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

void main() {
  test('a teammate moves an element from one page to another: the newer '
      'result of its new page, then an older result of its old page, leave '
      'it drawn on its new page only', () async {
    final store = await openCloudStore(MemoryEngine(MemoryStorage()));
    await addCloud(store, initialRows());
    final moved = withOp(
      initialRows(),
      movePatch('teammate', x: 30, pageId: 'page-b'),
    );
    final session = await sessionOf(store);
    await recordAll(store, [
      BaseArrived(
        pageReadOf(moved, 'page-b'),
        session: session,
        point: tick(),
      ),
    ]);
    await recordAll(store, [
      BaseArrived(
        pageReadOf(initialRows(), 'page-a'),
        session: session,
        point: tick(),
      ),
    ]);
    final onA = pageOf(await store.readPage(strategyId, 'page-a'));
    final onB = pageOf(await store.readPage(strategyId, 'page-b'));
    expect([
      for (final row in onA.elements) row.publicId,
    ], isNot(contains('e1')));
    expect(elementOn(onB, 'e1'), moved.element('e1'));
  });
}
