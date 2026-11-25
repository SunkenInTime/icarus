import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'support.dart';

Future<ResultSource> beganIn(LibraryStore store) async {
  final recorded = await recordAll(store, [const ReadBegun()]);
  return effectsOf(recorded).whereType<ReadStartIssued>().single.source;
}

Future<void> arriveIn(
  LibraryStore store,
  ArrivedBase base,
  ResultSource from,
) async {
  final recorded = await recordAll(store, [
    BaseArrived(base, session: await sessionOf(store), from: from),
  ]);
  expect(recorded.outcomes.single, isA<ReportApplied>());
}

Future<PageRow> pageRowIn(LibraryStore store, String page) async =>
    switch (await store.readPage(strategyId, page)) {
      Found(:final value) => value.page,
      final other => fail('page $page did not read: $other'),
    };

Future<List<String>> itemsOn(LibraryStore store, String page) async =>
    switch (await store.readPage(strategyId, page)) {
      Found(:final value) => [
        for (final row in value.elements)
          if (row is LiveElement) row.publicId,
      ],
      final other => fail('page $page did not read: $other'),
    };

StrategyRowSet movedToB(StrategyRowSet rows) =>
    withOp(rows, movePatch('to-b', pageId: 'page-b', x: 40));

StrategyRowSet purged(StrategyRowSet rows, String id) => StrategyRowSet(
  strategy: rows.strategy,
  pages: rows.pages,
  settings: rows.settings,
  elements: [
    for (final row in rows.elements)
      if (row.publicId != id) row,
  ],
  lineupGroups: rows.lineupGroups,
);

String? nameOf(PageRow row) => switch (row) {
  LivePage(:final name) => name,
  _ => null,
};

StrategyRowSet renamed(StrategyRowSet rows) => withOp(
  rows,
  const PagePatchOp(
    opId: 'rename',
    pagePublicId: 'page-a',
    expectedPageRevision: 1,
    name: 'Renamed on the server',
  ),
);

void main() {
  group('a row carried by more than one kind of result', () {
    test('a page list read before a page result, arriving after it, does not '
        'put back the page row the page result replaced, and the newer row '
        'is still there after a reopen', () async {
      final storage = MemoryStorage();
      var store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      final listStart = await beganIn(store);
      final pageStart = await beganIn(store);
      final newer = renamed(initialRows());

      await arriveIn(store, pageReadOf(newer, 'page-a'), pageStart);
      expect(nameOf(await pageRowIn(store, 'page-a')), 'Renamed on the server');

      await arriveIn(store, headerReadOf(initialRows()), listStart);
      expect(nameOf(await pageRowIn(store, 'page-a')), 'Renamed on the server');

      await store.close();
      store = await openCloudStore(MemoryEngine(storage));
      expect(nameOf(await pageRowIn(store, 'page-a')), 'Renamed on the server');
    });
  });
  test('a page result read before a page list, arriving after it, keeps the '
      'page row the list replaced, and after a reopen', () async {
    final storage = MemoryStorage();
    var store = await openCloudStore(MemoryEngine(storage));
    await addCloud(store, initialRows());
    final pageStart = await beganIn(store);
    final listStart = await beganIn(store);

    await arriveIn(store, headerReadOf(renamed(initialRows())), listStart);
    await arriveIn(store, pageReadOf(initialRows(), 'page-a'), pageStart);
    expect(nameOf(await pageRowIn(store, 'page-a')), 'Renamed on the server');

    await store.close();
    store = await openCloudStore(MemoryEngine(storage));
    expect(nameOf(await pageRowIn(store, 'page-a')), 'Renamed on the server');
  });

  group('an item and the page it is on', () {
    test('an older page result does not take an item back from the page a '
        'newer result moved it to', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      final olderA = await beganIn(store);
      final newerB = await beganIn(store);
      final moved = movedToB(initialRows());

      await arriveIn(store, pageReadOf(moved, 'page-b'), newerB);
      await arriveIn(store, pageReadOf(initialRows(), 'page-a'), olderA);
      expect(await itemsOn(store, 'page-b'), contains('e1'));
      expect(await itemsOn(store, 'page-a'), isNot(contains('e1')));
    });

    test('a page result read before the move, arriving after a newer result '
        'left the item out of the page it moved to (purged on the server), '
        'does not put it back', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      final olderA = await beganIn(store);
      final onB = await beganIn(store);
      final goneFromB = await beganIn(store);
      final moved = movedToB(initialRows());

      await arriveIn(store, pageReadOf(moved, 'page-b'), onB);
      await arriveIn(
        store,
        pageReadOf(purged(moved, 'e1'), 'page-b'),
        goneFromB,
      );
      await arriveIn(store, pageReadOf(initialRows(), 'page-a'), olderA);
      expect(await itemsOn(store, 'page-a'), isNot(contains('e1')));
      expect(await itemsOn(store, 'page-b'), isNot(contains('e1')));
    });

    test('a page result read before another page left an item out because it '
        'moved there is taken', () async {
      final store = await openCloudStore(MemoryEngine(MemoryStorage()));
      await addCloud(store, initialRows());
      final onB = await beganIn(store);
      final leftA = await beganIn(store);
      final moved = movedToB(initialRows());

      await arriveIn(store, pageReadOf(moved, 'page-a'), leftA);
      expect(await itemsOn(store, 'page-a'), isNot(contains('e1')));
      await arriveIn(store, pageReadOf(moved, 'page-b'), onB);
      expect(await itemsOn(store, 'page-b'), contains('e1'));
    });
  });
}
