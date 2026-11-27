import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/strategy_comparison.dart';
import 'package:icarus/library_store/library_migration.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/store_library.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

import '../library_rows/generated_strategies.dart';
import 'unit_harness.dart';

DateTime _storeClock() => DateTime.utc(2026, 11, 27, 10);

Future<LibraryStore> _open(StorageEngine engine) async =>
    switch (await LibraryStore.open(
      engine,
      canRead: appCanRead,
      clock: _storeClock,
    )) {
      StoreOpened(:final store) => store,
      StoreNotOpened(:final problem) => fail('$problem'),
    };

StrategyData _strategy(String id, {String? folderId, int pages = 2}) =>
    generatedStrategy(Optionals.unset).copyWith(
      id: id,
      name: 'Strategy $id',
      folderID: folderId,
      createdAt: DateTime.utc(2026, 3, 4, 5, 6, 7, 8),
      lastEdited: DateTime.utc(2026, 3, 7, 5, 6, 7, 8),
      pages: [
        for (var index = 0; index < pages; index++)
          generatedPage(
            id: '$id-p$index',
            sortIndex: index,
            optionals: Optionals.set,
            isAttack: index.isEven,
            itemPrefix: '$id-p$index',
          ),
      ],
    );

Folder _folder(String id, {String? parentId}) => Folder(
      name: 'Folder $id',
      id: id,
      dateCreated: DateTime.utc(2026),
      parentID: parentId,
    );

Future<void> _library() async {
  final folders = Hive.box<Folder>(HiveBoxNames.foldersBox);
  await folders.put('folder-1', _folder('folder-1'));
  await folders.put('folder-2', _folder('folder-2', parentId: 'folder-1'));
  final strategies = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
  for (final strategy in [
    _strategy('a'),
    _strategy('b', folderId: 'folder-1'),
    _strategy('c', folderId: 'folder-2'),
  ]) {
    await strategies.put(strategy.id, strategy);
  }
}

String _folders() => jsonEncode([
      for (final folder in const LocalLibrary().storedFolders)
        [
          folder.id,
          folder.name,
          folder.parentID,
          folder.iconId,
          folder.color.name,
          folder.customColor?.toARGB32(),
          folder.dateCreated.millisecondsSinceEpoch,
        ],
    ]);

Map<String, StrategyData> _strategies() => {
      for (final strategy in const LocalLibrary().storedStrategies)
        strategy.id: strategy,
    };

Future<void> _everyWrite() async {
  const library = LocalLibrary();
  (await library.addFolder(_folder('f3'))).orThrow();
  (await library.addFolder(_folder('f4', parentId: 'f3'))).orThrow();
  (await library.addStrategy(_strategy('n', folderId: 'f3'))).orThrow();
  (await library.renameStrategy(library.storedStrategy('a')!, 'Renamed'))
      .orThrow();
  (await library.moveStrategy(library.storedStrategy('b')!, 'f4')).orThrow();
  (await library.moveStrategy(library.storedStrategy('c')!, null)).orThrow();
  (await library.changePages(_strategy('c', pages: 3))).orThrow();
  (await library.saveStrategyFields(
    library.storedStrategy('a')!.copyWith(mapData: MapValue.haven),
  ))
      .orThrow();
  (await library.restyleFolder(
    library.storedFolder('folder-1')!,
    name: 'Restyled',
    iconId: 3,
    customColor: const Color(0xff112233),
    color: FolderColor.custom,
  ))
      .orThrow();
  (await library.moveFolder(library.storedFolder('folder-2')!, null))
      .orThrow();
  (await library.deleteStrategy('a')).orThrow();
  (await library.deleteStrategy('never-there')).orThrow();
  (await library.deleteFoldersWithStrategies(
    folderIds: ['f3', 'f4'],
    strategyIds: ['n', 'b'],
  ))
      .orThrow();
  (await library.deleteFolder('never-there')).orThrow();
}

Future<StoreLibrary> _loaded(LibraryStore store) async =>
    switch (await StoreLibrary.load(store)) {
      StoreLibraryLoaded(:final library) => library,
      StoreLibraryNotLoaded(:final why) => fail(why),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(openUnitHive);
  tearDown(() async {
    LocalLibrary.source = const LibraryInHive();
    await Hive.close();
  });

  Future<LibraryStore> moved(MemoryStorage storage) async {
    final store = await _open(MemoryEngine(storage));
    expect(
      await migrateLibraryIntoStore(
        store,
        strategies: [
          ...Hive.box<StrategyData>(HiveBoxNames.strategiesBox).values,
        ],
        folders: [...Hive.box<Folder>(HiveBoxNames.foldersBox).values],
      ),
      isA<MigrationFinishedNow>(),
    );
    return store;
  }

  test(
      'every write leaves the library on the store as it leaves the library '
      'in Hive, the store holds it after a reopen, and Hive is not written',
      () async {
    await _library();
    await StrategyMigrator.migrateAllStrategies();
    await _everyWrite();
    final inHive = _strategies();
    final foldersInHive = _folders();

    await Hive.close();
    await openUnitHive();
    await _library();
    final hiveBefore = jsonEncode({
      for (final strategy
          in Hive.box<StrategyData>(HiveBoxNames.strategiesBox).values)
        strategy.id: strategyFingerprint(strategy),
    });
    final storage = MemoryStorage();
    final store = await moved(storage);
    LocalLibrary.source = LibraryInStore(await _loaded(store));
    await StrategyMigrator.migrateAllStrategies();
    await _everyWrite();
    final onStore = _strategies();
    final foldersOnStore = _folders();
    await store.close();

    final reopened = await _open(MemoryEngine(storage));
    addTearDown(reopened.close);
    LocalLibrary.source = LibraryInStore(await _loaded(reopened));
    final afterReopen = _strategies();
    final foldersAfterReopen = _folders();

    expect(onStore.keys, inHive.keys);
    expect(afterReopen.keys, inHive.keys);
    for (final MapEntry(key: id, value: expected) in inHive.entries) {
      expect(strategyDifferences(expected, onStore[id]!), isEmpty, reason: id);
      expect(
        strategyDifferences(expected, afterReopen[id]!),
        isEmpty,
        reason: id,
      );
    }
    expect(foldersOnStore, foldersInHive);
    expect(foldersAfterReopen, foldersInHive);
    LocalLibrary.source = const LibraryInHive();
    expect(
      jsonEncode({
        for (final strategy
            in Hive.box<StrategyData>(HiveBoxNames.strategiesBox).values)
          strategy.id: strategyFingerprint(strategy),
      }),
      hiveBefore,
    );
  });

  test(
      'a write the store refuses fails loudly, and the library shows what it '
      'showed before it', () async {
    await _library();
    final store = await moved(MemoryStorage());
    addTearDown(store.close);
    LocalLibrary.source = LibraryInStore(await _loaded(store));
    const library = LocalLibrary();

    final intoNothing =
        await library.addStrategy(_strategy('lost', folderId: 'no-folder'));
    final b = library.storedStrategy('b')!;
    final moveIntoNothing = await library.moveStrategy(b, 'no-folder');
    final folder2 = library.storedFolder('folder-2')!;
    final underItself = await library.moveFolder(
      library.storedFolder('folder-1')!,
      'folder-2',
    );

    expect(intoNothing, isA<LibraryWriteFailed>());
    expect(library.holdsStrategy('lost'), isFalse);
    expect(moveIntoNothing, isA<LibraryWriteFailed>());
    expect(b.folderID, 'folder-1');
    expect(underItself, isA<LibraryWriteFailed>());
    expect(library.storedFolder('folder-1')!.parentID, isNull);
    expect(folder2.parentID, 'folder-1');
    final reread = await _loaded(store);
    expect(reread.strategies.containsKey('lost'), isFalse);
    expect(reread.strategies.get('b')!.folderID, 'folder-1');
  });

  test(
      'a delete takes what it deletes off the library before the store has '
      'answered, as a delete in Hive does', () async {
    await _library();
    final store = await moved(MemoryStorage());
    addTearDown(store.close);
    LocalLibrary.source = LibraryInStore(await _loaded(store));
    const library = LocalLibrary();

    final deleting = library.deleteFoldersWithStrategies(
      folderIds: ['folder-1', 'folder-2'],
      strategyIds: ['b', 'c'],
    );

    expect(library.holdsStrategy('b'), isFalse);
    expect(library.storedFolder('folder-2'), isNull);
    expect(await deleting, isA<LibraryWritten>());
    expect([for (final s in library.storedStrategies) s.id], ['a']);
  });

  test(
      'the library on the store tells its listeners about each change, and a '
      'listener for one strategy hears only that one', () async {
    await _library();
    final store = await moved(MemoryStorage());
    addTearDown(store.close);
    LocalLibrary.source = LibraryInStore(await _loaded(store));
    const library = LocalLibrary();
    var all = 0;
    var onlyA = 0;
    void countAll() => all++;
    void countA() => onlyA++;
    final everything = library.strategyRecords.listenable()
      ..addListener(countAll);
    final justA = library.strategyRecords.listenable(keys: ['a'])
      ..addListener(countA);

    (await library.renameStrategy(library.storedStrategy('b')!, 'B2'))
        .orThrow();
    await pumpEventQueue();
    (await library.renameStrategy(library.storedStrategy('a')!, 'A2'))
        .orThrow();
    await pumpEventQueue();
    everything.removeListener(countAll);
    justA.removeListener(countA);
    (await library.deleteStrategy('a')).orThrow();
    await pumpEventQueue();

    expect(all, 2);
    expect(onlyA, 1);
  });
}
