import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
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
}
