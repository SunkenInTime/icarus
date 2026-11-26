import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/folder_as_row.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_rows/strategy_comparison.dart';
import 'package:icarus/library_store/library_migration.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/stored_strategy.dart';
import 'package:icarus/migrations/hidden_folder_repair.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:path/path.dart' as path;

import '../library_rows/generated_strategies.dart';
import 'gated_engine.dart';
import 'hive_scratch.dart';
import 'unit_harness.dart';

final _startedAt = DateTime.utc(2026, 11, 26, 9);

DateTime _clock() => _startedAt;

DateTime _storeClock() => DateTime.utc(2026, 11, 26, 10);

Future<LibraryStore> _open(StorageEngine engine) async =>
    switch (await LibraryStore.open(
      engine,
      canRead: appCanRead,
      clock: _storeClock,
    )) {
      StoreOpened(:final store) => store,
      StoreNotOpened(:final problem) => fail('$problem'),
    };

List<StrategyData> _hiveStrategies() =>
    Hive.box<StrategyData>(HiveBoxNames.strategiesBox).values.toList();

List<Folder> _hiveFolders() =>
    Hive.box<Folder>(HiveBoxNames.foldersBox).values.toList();

Future<LibraryMigration> _migrate(LibraryStore store) =>
    migrateLibraryIntoStore(
      store,
      strategies: _hiveStrategies(),
      folders: _hiveFolders(),
      clock: _clock,
    );

String _hiveBytes() => jsonEncode({
      for (final strategy in _hiveStrategies())
        strategy.id: strategyFingerprint(strategy),
      for (final folder in _hiveFolders())
        folder.id: [folder.name, folder.parentID, folder.iconId],
    });

const _contents = DeepCollectionEquality();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(openUnitHive);
  tearDown(Hive.close);

  StrategyData strategy(String id, {String? folderId, List<int>? sortIndexes}) {
    final made = generatedStrategy(Optionals.unset);
    return made.copyWith(
      id: id,
      name: 'Strategy $id',
      folderID: folderId,
      pages: [
        for (final (index, sortIndex) in (sortIndexes ?? const [0, 1]).indexed)
          generatedPage(
            id: '$id-p$index',
            sortIndex: sortIndex,
            optionals: Optionals.set,
            isAttack: index.isEven,
            itemPrefix: '$id-p$index',
          ),
      ],
    );
  }

  StrategyData legacy(String id) => StrategyData(
        id: id,
        name: 'Strategy $id',
        mapData: MapValue.ascent,
        versionNumber: 6,
        lastEdited: DateTime.utc(2024, 3, 1),
        folderID: null,
        // ignore: deprecated_member_use_from_same_package
        abilityData: [
          PlacedAbility(
            id: '$id-blaze',
            data: AgentData.agents[AgentType.pheonix]!.abilities.first,
            position: const Offset(300, 400),
            isAlly: true,
          ),
        ],
      );

  Future<void> library(List<StrategyData> strategies) async {
    final folders = Hive.box<Folder>(HiveBoxNames.foldersBox);
    await folders.put(
      'folder-1',
      Folder(name: 'Retakes', id: 'folder-1', dateCreated: DateTime.utc(2026)),
    );
    await folders.put(
      'folder-2',
      Folder(
        name: 'B site',
        id: 'folder-2',
        dateCreated: DateTime.utc(2026),
        parentID: 'folder-1',
      ),
    );
    for (final strategy in strategies) {
      await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
          .put(strategy.id, strategy);
    }
  }

  Future<StrategyData> readBack(LibraryStore store, String id) async =>
      switch (await readStoredRows(store, id)) {
        StoredRowsRead(:final rows) => switch (strategyOfRows(rows)) {
            StoredAsData(:final strategy) => strategy,
            final other => fail('$id reads back as $other'),
          },
        StoredRowsNot(:final stored) => fail('$id is not read: $stored'),
      };

  test(
      'copies every strategy and folder, each reading back as its Hive record '
      'brought up to date, records that it finished, and leaves Hive as it '
      'was', () async {
    await library([
      strategy('a'),
      strategy('b', folderId: 'folder-1'),
      strategy('c', folderId: 'folder-2'),
    ]);
    final before = _hiveBytes();
    final writes = await HiveWrites.watch(Directory(path.dirname(
      Hive.box<StrategyData>(HiveBoxNames.strategiesBox).path!,
    )));
    final store = await _open(MemoryEngine(MemoryStorage()));
    addTearDown(store.close);

    final migration = await _migrate(store);

    expect(migration, isA<MigrationFinishedNow>());
    final record = (migration as MigrationFinishedNow).record;
    expect(record.strategies, isEmpty);
    expect(record.folders, isEmpty);
    expect(store.migration, isA<MigrationFinished>());
    for (final hive in _hiveStrategies()) {
      final current = await StrategyMigrator.migrateLegacyData(hive.copyWith());
      expect(
        strategyDifferences(current, await readBack(store, hive.id)),
        isEmpty,
        reason: hive.id,
      );
    }
    final list = (store.library as LibraryOpen).list;
    expect(
      {
        for (final row in list.folders.cast<ReadableFolder>())
          row.publicId: row.parentFolderPublicId,
      },
      {'folder-1': null, 'folder-2': 'folder-1'},
    );
    expect(_hiveBytes(), before);
    expect(await writes.stop(), isEmpty);
  });

  test('a migration that finished runs again never, whatever Hive holds since',
      () async {
    await library([strategy('a'), strategy('b')]);
    final storage = MemoryStorage();
    final first = await _open(MemoryEngine(storage));
    expect(await _migrate(first), isA<MigrationFinishedNow>());
    await first.close();
    final finished = storage.contents;
    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .put('new', strategy('new'));
    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).delete('a');

    final again = await _open(MemoryEngine(storage));
    addTearDown(again.close);
    final migration = await _migrate(again);

    expect(migration, isA<MigrationWasFinished>());
    await again.close();
    expect(_contents.equals(storage.contents, finished), isTrue);
  });

  group('a copy stopped after any engine commit', () {
    Future<Map<String, Map<String, String>>> uninterrupted() async {
      final storage = MemoryStorage();
      final store = await _open(MemoryEngine(storage));
      expect(await _migrate(store), isA<MigrationFinishedNow>());
      await store.close();
      return storage.contents;
    }

    test(
        'and run again on the next start ends as a run that was never '
        'stopped, at every point including just before the finished record',
        () async {
      await library([
        strategy('a'),
        strategy('b', folderId: 'folder-1'),
        strategy('c', folderId: 'folder-2'),
      ]);
      final expected = await uninterrupted();
      final counting = CommitGate();
      final whole =
          await _open(GatedEngine(MemoryEngine(MemoryStorage()), counting));
      await _migrate(whole);
      await whole.close();
      final commits = counting.commits;
      expect(commits, greaterThan(5));

      for (var stopAfter = 0; stopAfter < commits; stopAfter++) {
        final storage = MemoryStorage();
        final gate = CommitGate()..endAfter = stopAfter;
        final stopped = await _open(GatedEngine(MemoryEngine(storage), gate));
        expect(
          await _migrate(stopped),
          isA<MigrationStopped>(),
          reason: 'stopped after $stopAfter commits',
        );
        await stopped.close();
        final interrupted = storage.contents;
        expect(
          _contents.equals(interrupted, expected),
          isFalse,
          reason: 'stopped after $stopAfter commits',
        );

        final next = await _open(MemoryEngine(storage));
        expect(
          next.migration,
          stopAfter == 0 ? isA<MigrationNotStarted>() : isA<MigrationCopying>(),
          reason: 'stopped after $stopAfter commits',
        );
        expect(
          await _migrate(next),
          isA<MigrationFinishedNow>(),
          reason: 'stopped after $stopAfter commits',
        );
        await next.close();
        expect(
          _contents.equals(storage.contents, expected),
          isTrue,
          reason: 'stopped after $stopAfter commits',
        );
      }
    });
  });

  test(
      'a strategy that will not convert is left behind, named with its reason, '
      'and kept in Hive; the others are copied', () async {
    final good = strategy('good');
    final repeated = strategy('outside');
    final outside = repeated.copyWith(pages: [
      repeated.pages[0],
      repeated.pages[1].copyWith(id: repeated.pages[0].id),
    ]);
    await library([good, outside]);
    final store = await _open(MemoryEngine(MemoryStorage()));
    addTearDown(store.close);

    final migration = await _migrate(store) as MigrationFinishedNow;

    expect(
      [for (final left in migration.record.strategies) left.publicId],
      ['outside'],
    );
    expect(migration.record.strategies.single.name, 'Strategy outside');
    expect(
      migration.record.strategies.single.reason,
      startsWith('it could not be converted'),
    );
    expect(
      Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get('outside'),
      isNotNull,
    );
    expect(
      [
        for (final summary in (store.library as LibraryOpen).list.strategies)
          summary.publicId,
      ],
      ['good'],
    );
  });

  test(
      'a strategy saved by a newer version of Icarus is left behind as it '
      'is, never brought down to this version', () async {
    final newer = strategy('newer').copyWith(
      versionNumber: Settings.versionNumber + 1,
    );
    await library([strategy('a'), newer]);
    final store = await _open(MemoryEngine(MemoryStorage()));
    addTearDown(store.close);

    final migration = await _migrate(store) as MigrationFinishedNow;

    expect(
      [
        for (final left in migration.record.strategies)
          (left.publicId, left.reason),
      ],
      [
        (
          'newer',
          'it could not be converted: it was saved by a newer version of '
              'Icarus (${Settings.versionNumber + 1})',
        ),
      ],
    );
  });

  test(
      'pages at the same position come back in the order the app shows them '
      'in, Hive\'s order between them', () async {
    final made = strategy('tied', sortIndexes: [1, 0, 1]);
    final tied = made.copyWith(pages: [
      made.pages[0].copyWith(id: 'tied-z'),
      made.pages[1].copyWith(id: 'tied-m'),
      made.pages[2].copyWith(id: 'tied-a'),
    ]);
    await library([tied]);
    final store = await _open(MemoryEngine(MemoryStorage()));
    addTearDown(store.close);

    await _migrate(store);

    final back = await readBack(store, 'tied');
    final shown = [...back.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    expect(
      [for (final page in shown) page.id],
      ['tied-m', 'tied-z', 'tied-a'],
    );
  });

  test('a migration record this build cannot read stops it touching anything',
      () async {
    await library([strategy('a')]);
    final storage = MemoryStorage({
      'library': {'migration': '{"state": "half done"}'},
    });
    final store = await _open(MemoryEngine(storage));
    addTearDown(store.close);
    final before = storage.contents;

    expect(await _migrate(store), isA<MigrationRecordUnreadable>());
    expect(_contents.equals(storage.contents, before), isTrue);
  });

  for (final (what, held) in [
    (
      'a local strategy',
      (LibraryStore store) async {
        final rows =
            (strategyToRows(strategy('held')) as StrategyRowsMade).rows;
        expect(await store.putStrategy(rows), isA<Saved>());
      }
    ),
    (
      'a folder',
      (LibraryStore store) async {
        expect(
          await store.editLibrary([
            PutFolder(folderToRow(Folder(
              name: 'Held',
              id: 'held-folder',
              dateCreated: DateTime.utc(2026),
            ))),
          ]),
          isA<Saved>(),
        );
      }
    ),
  ]) {
    test(
        'a store that already holds $what and has no record of a copy is '
        'left exactly as it was, and the move is not run', () async {
      await library([strategy('a')]);
      final hive = _hiveBytes();
      final storage = MemoryStorage();
      final earlier = await _open(MemoryEngine(storage));
      await held(earlier);
      await earlier.close();
      final before = storage.contents;
      final store = await _open(MemoryEngine(storage));

      final migration = await _migrate(store);
      await store.close();

      expect(
        migration,
        isA<MigrationNotRun>()
            .having((notRun) => notRun.why, 'why', storeHoldsALibrary),
      );
      expect(_contents.equals(storage.contents, before), isTrue);
      expect(_hiveBytes(), hive);
    });
  }

  test(
      'a strategy and folder under a folder that is gone are copied where the '
      'Hive start-up repair puts them, with everything beneath them, and '
      'nothing is left behind', () async {
    await library([
      strategy('in-lost', folderId: 'lost'),
      strategy('in-lost-child', folderId: 'lost-child'),
      strategy('in-gone', folderId: 'gone'),
    ]);
    final folders = Hive.box<Folder>(HiveBoxNames.foldersBox);
    await folders.put(
      'lost',
      Folder(
        name: 'Lost',
        id: 'lost',
        dateCreated: DateTime.utc(2026),
        parentID: 'gone',
      ),
    );
    await folders.put(
      'lost-child',
      Folder(
        name: 'Lost child',
        id: 'lost-child',
        dateCreated: DateTime.utc(2026),
        parentID: 'lost',
      ),
    );
    final store = await _open(MemoryEngine(MemoryStorage()));
    addTearDown(store.close);

    final migration = await _migrate(store) as MigrationFinishedNow;
    await moveOrphansToTopLevel(
      folders,
      Hive.box<StrategyData>(HiveBoxNames.strategiesBox),
    );

    expect(migration.record.strategies, isEmpty);
    expect(migration.record.folders, isEmpty);
    final list = (store.library as LibraryOpen).list;
    expect(
      {
        for (final row in list.folders.cast<ReadableFolder>())
          row.publicId: row.parentFolderPublicId,
      },
      {for (final folder in _hiveFolders()) folder.id: folder.parentID},
    );
    expect(
      {
        for (final summary in list.strategies)
          summary.publicId: summary.folderPublicId,
      },
      {
        for (final strategy in _hiveStrategies()) strategy.id: strategy.folderID
      },
    );
    expect(
      {
        for (final summary in list.strategies)
          summary.publicId: summary.folderPublicId
      },
      {'in-lost': 'lost', 'in-lost-child': 'lost-child', 'in-gone': null},
    );
  });

  test(
      'a strategy from before pages leaves its Hive record as it was, and is '
      'copied as the start-up migration on Hive would bring it up to date, '
      'its square ability moved once', () async {
    await library([legacy('old')]);
    final store = await _open(MemoryEngine(MemoryStorage()));
    addTearDown(store.close);

    await _migrate(store);

    final hive = Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get('old')!;
    expect(
      // ignore: deprecated_member_use_from_same_package
      [for (final ability in hive.abilityData) ability.position],
      [const Offset(300, 400)],
    );
    expect(hive.pages, isEmpty);
    final onHive = StrategyMigrator.migrateToCurrentVersion(
      await StrategyMigrator.migrateLegacyData(legacy('old')),
    );
    final back = await readBack(store, 'old');
    expect(back.pages, hasLength(1));
    expect(
      [for (final ability in back.pages.single.abilityData) ability.toJson()],
      [
        for (final ability in onHive.pages.single.abilityData) ability.toJson(),
      ],
    );
  });

  test(
      'a copy stopped part way and run again after Hive changed ends as a '
      'first copy of the changed Hive would', () async {
    await library([
      strategy('a'),
      strategy('b', folderId: 'folder-1'),
      strategy('c', folderId: 'folder-2'),
    ]);
    final counting = CommitGate();
    final whole =
        await _open(GatedEngine(MemoryEngine(MemoryStorage()), counting));
    await _migrate(whole);
    await whole.close();

    for (var stopAfter = 1; stopAfter < counting.commits; stopAfter++) {
      await Hive.close();
      await openUnitHive();
      await library([
        strategy('a'),
        strategy('b', folderId: 'folder-1'),
        strategy('c', folderId: 'folder-2'),
      ]);
      final storage = MemoryStorage();
      final stopped = await _open(
        GatedEngine(MemoryEngine(storage), CommitGate()..endAfter = stopAfter),
      );
      expect(await _migrate(stopped), isA<MigrationStopped>());
      await stopped.close();

      final strategies = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
      await strategies.put(
        'b',
        strategy('b', folderId: 'folder-1').copyWith(
          versionNumber: Settings.versionNumber + 1,
        ),
      );
      await strategies.put('c', strategy('c'));
      await Hive.box<Folder>(HiveBoxNames.foldersBox).delete('folder-2');
      final fresh = MemoryStorage();
      final first = await _open(MemoryEngine(fresh));
      expect(await _migrate(first), isA<MigrationFinishedNow>());
      await first.close();

      final again = await _open(MemoryEngine(storage));
      expect(await _migrate(again), isA<MigrationFinishedNow>());
      await again.close();
      expect(
        _contents.equals(storage.contents, fresh.contents),
        isTrue,
        reason: 'stopped after $stopAfter commits',
      );
    }
  });

  test(
      'a strategy from before pages, copied again after a stop at any commit, '
      'is in the store once with one page', () async {
    await library([strategy('a'), legacy('old'), strategy('z')]);
    final uninterrupted = await _open(MemoryEngine(MemoryStorage()));
    await _migrate(uninterrupted);
    final rows = uninterrupted.rowsCountedFor('old');
    await uninterrupted.close();
    final counting = CommitGate();
    final whole =
        await _open(GatedEngine(MemoryEngine(MemoryStorage()), counting));
    await _migrate(whole);
    await whole.close();

    for (var stopAfter = 0; stopAfter < counting.commits; stopAfter++) {
      final storage = MemoryStorage();
      final stopped = await _open(
        GatedEngine(MemoryEngine(storage), CommitGate()..endAfter = stopAfter),
      );
      expect(await _migrate(stopped), isA<MigrationStopped>());
      await stopped.close();
      final next = await _open(MemoryEngine(storage));
      expect(await _migrate(next), isA<MigrationFinishedNow>());

      final back = await readBack(next, 'old');
      expect(back.pages, hasLength(1), reason: 'stopped after $stopAfter');
      expect(next.rowsCountedFor('old'), rows,
          reason: 'stopped after $stopAfter');
      expect(
        [
          for (final summary in (next.library as LibraryOpen).list.strategies)
            summary.publicId,
        ]..sort(),
        ['a', 'old', 'z'],
      );
      await next.close();
    }
  });
}
