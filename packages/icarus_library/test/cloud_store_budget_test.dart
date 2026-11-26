import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

StrategyRowSet twentyPages() {
  final pages = [
    for (var index = 0; index < 20; index++)
      page('page-$index', sortIndex: index),
  ];
  return strategyRows(
    pages: pages,
    elements: [
      for (final row in pages)
        for (var item = 0; item < 300; item++)
          element('${row.publicId}-item-$item', pageId: row.publicId),
    ],
  );
}

List<String> contentListed(Counts counts) => [
  for (final (_, prefix) in counts.entryListings)
    if (prefix.startsWith('content/')) prefix,
];

void main() {
  group('a cloud strategy of 20 pages of 300 items that agrees with its '
      'queue', () {
    late Contents disk;

    setUpAll(() async {
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, twentyPages());
      await store.close();
      disk = editable(storage.contents);
    });

    test('opening the store and reading the strategy reads no page content '
        'and writes nothing', () async {
      final (engine, counts) = counting(MemoryEngine(MemoryStorage(disk)));
      final store = await openCloudStore(engine);
      await store.readStrategy(strategyId);
      expect(contentListed(counts), isEmpty);
      final area = strategyArea(strategyId);
      expect(counts.reads, [(area, 'strategy'), (area, 'cloud')]);
      expect(counts.keyListings, [(area, '')]);
      expect(counts.entryListings, [
        ('library', ''),
        for (final prefix in [
          'page/',
          'settings/',
          'pending/',
          'attempt/',
          'landed/',
          'read/',
        ])
          (area, prefix),
      ]);
      expect(counts.commits, 0);
    });

    test('reading a page lists only that page and writes nothing', () async {
      final (engine, counts) = counting(MemoryEngine(MemoryStorage(disk)));
      final store = await openCloudStore(engine);
      await store.readStrategy(strategyId);
      counts.reset();
      await store.readPage(strategyId, 'page-7');
      expect(contentListed(counts), ['content/${digestOf('page-7')}/']);
      expect(counts.reads, isEmpty);
      expect(counts.commits, 0);
    });

    test('a page list that keeps every page reads no page content, and a '
        'page result that changes nothing reads only its own page; neither '
        'writes', () async {
      final (engine, counts) = counting(MemoryEngine(MemoryStorage(disk)));
      final store = await openCloudStore(engine);
      await recordAll(store, [const AppRestarted(build: build)]);
      final listStart = await beganIn(store);
      final listSession = await sessionOf(store);
      counts.reset();
      await recordAll(store, [
        BaseArrived(
          headerReadOf(twentyPages()),
          session: listSession,
          from: listStart,
        ),
      ]);
      expect(contentListed(counts), isEmpty);
      expect(counts.commits, 0);
      final pageStart = await beganIn(store);
      final pageSession = await sessionOf(store);
      counts.reset();
      await recordAll(store, [
        BaseArrived(
          pageReadOf(twentyPages(), 'page-7'),
          session: pageSession,
          from: pageStart,
        ),
      ]);
      expect(contentListed(counts), ['content/${digestOf('page-7')}/']);
      expect(counts.commits, 0);
    });
  });
}
