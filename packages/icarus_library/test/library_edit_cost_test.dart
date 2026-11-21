import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

StrategyRowSet _small(String id) => StrategyRowSet(
  strategy: strategyRow(publicId: id),
  pages: [
    LivePage(
      publicId: '$id-page',
      strategyPublicId: id,
      name: 'Page 1',
      sortIndex: 0,
      isAttack: true,
      revision: 1,
    ),
  ],
  settings: [settings('$id-page')],
);

Future<Contents> libraryOf(int strategies) async {
  final storage = MemoryStorage();
  final store = await openStore(MemoryEngine(storage));
  savedValue(
    await store.editLibrary([
      PutFolder(ReadableFolder(publicId: 'folder', name: 'Folder')),
      for (var i = 0; i < strategies; i++) AddStrategy(_small('s$i')),
    ]),
  );
  await store.close();
  return storage.contents;
}

List<int> _work(Counts counts) => [
  counts.reads.length,
  counts.areaListings.length,
  counts.keyListings.length,
  counts.entryListings.length,
  counts.listedKeys,
  counts.listedEntries.length,
  counts.written.length,
  counts.deleted.length,
  counts.commits,
];

Future<Map<String, List<int>>> workAt(Contents library) async {
  final (engine, counts) = counting(MemoryEngine(MemoryStorage(library)));
  final store = await openStore(engine);
  final work = <String, List<int>>{};
  Future<void> measure(String what, LibraryChange change) async {
    counts.reset();
    savedValue(await store.editLibrary([change]));
    work[what] = _work(counts);
  }

  await measure('add', AddStrategy(_small('new')));
  await measure('move', const MoveStrategy('new', 'folder'));
  await measure('move one already listed', const MoveStrategy('s7', 'folder'));
  await measure('remove', const RemoveStrategy('new'));
  await store.close();
  return work;
}

void main() {
  test(
    'adding, moving and removing a strategy ask the engine for the same work '
    'in a library of 100 strategies as in one of 2,800',
    () async {
      final small = await workAt(await libraryOf(100));
      final large = await workAt(await libraryOf(2800));
      expect(large, small);
      expect(small['add']!.reduce((a, b) => a + b), greaterThan(0));
    },
  );
}
