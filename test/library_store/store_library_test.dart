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
import 'gated_engine.dart';
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

String _foldersOf(Iterable<Folder> folders) => jsonEncode([
      for (final folder in folders)
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

typedef _Seen = ({Map<String, StrategyData> strategies, String folders});

_Seen _seen() => (
      strategies: {
        for (final strategy in const LocalLibrary().storedStrategies)
          strategy.id: wholeCopyOf(strategy),
      },
      folders: _foldersOf(const LocalLibrary().storedFolders),
    );

String _hiveOnDisk() => jsonEncode({
      'strategies': {
        for (final strategy
            in Hive.box<StrategyData>(HiveBoxNames.strategiesBox).values)
          strategy.id: strategyFingerprint(strategy),
      },
      'folders': _foldersOf(Hive.box<Folder>(HiveBoxNames.foldersBox).values),
    });

void _expectSame(_Seen actual, _Seen expected, String step) {
  expect(actual.strategies.keys, expected.strategies.keys, reason: step);
  for (final MapEntry(key: id, value: strategy)
      in expected.strategies.entries) {
    expect(
      strategyDifferences(strategy, actual.strategies[id]!),
      isEmpty,
      reason: '$step: $id',
    );
  }
  expect(actual.folders, expected.folders, reason: step);
}

typedef _Step = (String, Future<LibraryWrite> Function(LocalLibrary library));

final List<_Step> _everyWrite = [
  ('add a folder', (library) => library.addFolder(_folder('f3'))),
  (
    'add a child folder',
    (library) => library.addFolder(_folder('f4', parentId: 'f3')),
  ),
  (
    'add a strategy',
    (library) => library.addStrategy(_strategy('n', folderId: 'f3')),
  ),
  (
    'rename a strategy',
    (library) =>
        library.renameStrategy(library.storedStrategy('a')!, 'Renamed'),
  ),
  (
    'move a strategy into a folder',
    (library) => library.moveStrategy(library.storedStrategy('b')!, 'f4'),
  ),
  (
    'move a strategy to the top',
    (library) => library.moveStrategy(library.storedStrategy('c')!, null),
  ),
  (
    'change pages',
    (library) => library.changePages(_strategy('c', pages: 3)),
  ),
  (
    'save fields',
    (library) => library.saveStrategyFields(
          library.storedStrategy('a')!.copyWith(mapData: MapValue.haven),
        ),
  ),
  (
    'restyle a folder',
    (library) => library.restyleFolder(
          library.storedFolder('folder-1')!,
          name: 'Restyled',
          iconId: 3,
          customColor: const Color(0xff112233),
          color: FolderColor.custom,
        ),
  ),
  (
    'move a folder to the top',
    (library) => library.moveFolder(library.storedFolder('folder-2')!, null),
  ),
  ('delete a strategy', (library) => library.deleteStrategy('a')),
  (
    'delete a strategy that is not there',
    (library) => library.deleteStrategy('never-there'),
  ),
  (
    'delete folders with their strategies',
    (library) => library.deleteFoldersWithStrategies(
          folderIds: ['f3', 'f4'],
          strategyIds: ['n', 'b'],
        ),
  ),
  (
    'delete a folder that is not there',
    (library) => library.deleteFolder('never-there'),
  ),
];

Future<StoreLibrary> _loaded(LibraryStore store, {List<String>? lost}) async =>
    switch (await StoreLibrary.load(store, lost: (why) => lost?.add(why))) {
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

  Future<LibraryStore> moved(StorageEngine engine) async {
    final store = await _open(engine);
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

  Future<_Seen> reopened(MemoryStorage storage) async {
    final store = await _open(MemoryEngine(storage));
    final library = await _loaded(store);
    await store.close();
    return (
      strategies: {
        for (final strategy in library.strategies.values) strategy.id: strategy,
      },
      folders: _foldersOf(library.folders.values),
    );
  }

  test(
      'after every write the library on the store is the library in Hive, '
      'and the store holds it after a reopen; Hive is not written', () async {
    await _library();
    await StrategyMigrator.migrateAllStrategies();
    final inHive = <_Seen>[];
    for (final (_, write) in _everyWrite) {
      (await write(const LocalLibrary())).orThrow();
      inHive.add(_seen());
    }

    await Hive.close();
    await openUnitHive();
    await _library();
    final hiveBefore = _hiveOnDisk();
    final storage = MemoryStorage();
    final store = await moved(MemoryEngine(storage));
    LocalLibrary.source = LibraryInStore(await _loaded(store));
    await StrategyMigrator.migrateAllStrategies();
    for (final (index, (step, write)) in _everyWrite.indexed) {
      (await write(const LocalLibrary())).orThrow();
      _expectSame(_seen(), inHive[index], step);
    }
    await store.close();

    _expectSame(await reopened(storage), inHive.last, 'after a reopen');
    LocalLibrary.source = const LibraryInHive();
    expect(_hiveOnDisk(), hiveBefore);
  });

  group('a write the store would refuse is refused before it shows', () {
    late LibraryStore store;
    late MemoryStorage storage;

    setUp(() async {
      await _library();
      storage = MemoryStorage();
      store = await moved(MemoryEngine(storage));
      LocalLibrary.source = LibraryInStore(await _loaded(store));
    });
    tearDown(() => store.close());

    Future<void> refused(Future<LibraryWrite> write) async {
      final before = _seen();
      final heard = <String>[];
      final listening = const LocalLibrary().strategyRecords.changes().listen(
            heard.add,
          );
      expect(await write, isA<LibraryWriteFailed>());
      await pumpEventQueue();
      await listening.cancel();
      expect(heard, isEmpty);
      _expectSame(_seen(), before, 'in memory');
      await store.close();
      _expectSame(await reopened(storage), before, 'after a reopen');
    }

    test('a strategy into a folder that is not there', () async {
      await refused(const LocalLibrary().addStrategy(
        _strategy('lost', folderId: 'no-folder'),
      ));
    });

    test('a move into a folder that is not there', () async {
      await refused(const LocalLibrary().moveStrategy(
        const LocalLibrary().storedStrategy('b')!,
        'no-folder',
      ));
    });

    test('a folder under its own child', () async {
      await refused(const LocalLibrary().moveFolder(
        const LocalLibrary().storedFolder('folder-1')!,
        'folder-2',
      ));
    });

    test('a rename through a record deleted meanwhile', () async {
      const library = LocalLibrary();
      final held = library.storedStrategy('a')!;
      (await library.deleteStrategy('a')).orThrow();
      await refused(library.renameStrategy(held, 'Back from the dead'));
    });

    test('a restyle through a record replaced meanwhile', () async {
      const library = LocalLibrary();
      final held = library.storedFolder('folder-1')!;
      (await library.addFolder(_folder('folder-1'))).orThrow();
      await refused(library.restyleFolder(
        held,
        name: 'Old record',
        iconId: 2,
        customColor: null,
        color: FolderColor.blue,
      ));
    });
  });

  group('two writes in flight', () {
    late CommitGate gate;
    late MemoryStorage storage;
    late LibraryStore store;
    late List<String> lost;

    setUp(() async {
      await _library();
      gate = CommitGate();
      storage = MemoryStorage();
      store = await moved(GatedEngine(MemoryEngine(storage), gate));
      lost = [];
      LocalLibrary.source = LibraryInStore(await _loaded(store, lost: lost));
    });
    tearDown(() => store.close());

    test(
        'a move into a missing folder during an autosave leaves the strategy '
        'where it was, in memory and in the store', () async {
      const library = LocalLibrary();
      final b = library.storedStrategy('b')!;

      final moving = library.moveStrategy(b, 'no-folder');
      final saving = library.saveStrategyFields(
        library.storedStrategy('b')!.copyWith(name: 'Saved'),
      );

      expect(await moving, isA<LibraryWriteFailed>());
      expect(await saving, isA<LibraryWritten>());
      expect(library.storedStrategy('b')!.folderID, 'folder-1');
      expect(library.storedStrategy('b')!.name, 'Saved');
      await store.close();
      final back = await reopened(storage);
      expect(back.strategies['b']!.folderID, 'folder-1');
      expect(back.strategies['b']!.name, 'Saved');
    });

    test(
        'two renames, the first not saved: the library ends as the store '
        'does', () async {
      const library = LocalLibrary();
      gate
        ..hold()
        ..failNext = true;

      final first = library.renameStrategy(library.storedStrategy('a')!, 'X');
      final second = library.renameStrategy(library.storedStrategy('a')!, 'Y');
      gate.release();

      expect(await first, isA<LibraryWriteFailed>());
      expect(await second, isA<LibraryWritten>());
      expect(lost, isEmpty);
      final now = _seen();
      await store.close();
      _expectSame(await reopened(storage), now, 'after a reopen');
      expect(now.strategies['a']!.name, 'Y');
    });

    test(
        'a folder delete while a move into the folder fails deletes nothing '
        'it was not asked to, and the library ends as the store does',
        () async {
      const library = LocalLibrary();
      gate
        ..hold()
        ..failNext = true;

      final moving =
          library.moveStrategy(library.storedStrategy('a')!, 'folder-2');
      final deleting = library.deleteFoldersWithStrategies(
        folderIds: ['folder-2'],
        strategyIds: ['c', 'a'],
      );
      gate.release();

      expect(await moving, isA<LibraryWriteFailed>());
      expect(await deleting, isA<LibraryWriteFailed>());
      final now = _seen();
      expect(now.strategies.keys, containsAll(['a', 'c']));
      expect(now.strategies['a']!.folderID, isNull);
      await store.close();
      _expectSame(await reopened(storage), now, 'after a reopen');
    });

    test(
        'a write that ends in doubt leaves the library as the reopened store '
        'holds it, or not opened', () async {
      const library = LocalLibrary();
      gate.doubtNext = true;

      final written = await library.deleteStrategy('a');

      expect(written, isA<LibraryWriteFailed>());
      if (lost.isEmpty) {
        final now = _seen();
        await store.close();
        _expectSame(await reopened(storage), now, 'after a reopen');
      } else {
        expect(lost.single, contains('the store is shut'));
      }
    });
  });

  test(
      'a delete takes what it deletes off the library before the store has '
      'answered, as a delete in Hive does, and the store has it gone too',
      () async {
    await _library();
    final storage = MemoryStorage();
    final store = await moved(MemoryEngine(storage));
    LocalLibrary.source = LibraryInStore(await _loaded(store));
    const library = LocalLibrary();

    final deleting = library.deleteFoldersWithStrategies(
      folderIds: ['folder-1', 'folder-2'],
      strategyIds: ['b', 'c'],
    );

    expect(library.holdsStrategy('b'), isFalse);
    expect(library.storedFolder('folder-2'), isNull);
    expect(await deleting, isA<LibraryWritten>());
    await store.close();
    final back = await reopened(storage);
    expect(back.strategies.keys, ['a']);
    expect(back.folders, _foldersOf(const []));
  });

  test(
      'the library on the store tells its listeners about each change, and a '
      'listener for one strategy hears only that one', () async {
    await _library();
    final store = await moved(MemoryEngine(MemoryStorage()));
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

    expect(all, greaterThanOrEqualTo(2));
    expect(onlyA, greaterThanOrEqualTo(1));
    expect(all, greaterThan(onlyA));
  });

  test('a store with a row it could not place is not loaded', () async {
    await _library();
    final storage = MemoryStorage();
    final store = await moved(MemoryEngine(storage));
    await store.close();
    final contents = storage.contents;
    final damaged = MemoryStorage({
      ...contents,
      'library': {
        ...contents['library']!,
        'folder/${digestOf('folder-3')}': '[[[',
      },
    });
    final reopenedStore = await _open(MemoryEngine(damaged));
    addTearDown(reopenedStore.close);

    final load = await StoreLibrary.load(reopenedStore, lost: (_) {});

    expect(
      load,
      isA<StoreLibraryNotLoaded>().having(
        (notLoaded) => notLoaded.why,
        'why',
        startsWith('a row could not be placed'),
      ),
    );
  });
}
