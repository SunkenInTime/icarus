import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_store_support.dart';
import 'store_support.dart';
import 'support.dart';

void main() {
  test('Sol #3 in the store: after a complete read, a replacement on another '
      'page is drawn there and not on the page of its earlier life, whichever '
      'page the read reaches first', () async {
    for (final order in [
      ['page-b', 'page-a'],
      ['page-a', 'page-b'],
    ]) {
      var clock = fixedClock();
      final store = await openCloudStore(
        MemoryEngine(MemoryStorage()),
        clock: () => clock,
      );
      await addCloud(
        store,
        strategyRows(
          elements: [
            element('e1', revision: 2),
            element('e2'),
            element('e3', pageId: 'page-b'),
          ],
        ),
      );
      clock = clock.add(const Duration(days: 31));
      final server = strategyRows(
        elements: [
          element('e2'),
          element('e3', pageId: 'page-b'),
          element('e1', pageId: 'page-b', fields: const {'rotation': 135}),
        ],
      );
      await readServer(store, server, pages: order);
      final onB = pageOf(await store.readPage(strategyId, 'page-b'));
      final onA = pageOf(await store.readPage(strategyId, 'page-a'));
      expect(elementOn(onB, 'e1'), server.element('e1'), reason: '$order');
      expect(
        [for (final row in onA.elements) row.publicId],
        isNot(contains('e1')),
        reason: '$order',
      );
    }
  });
}
