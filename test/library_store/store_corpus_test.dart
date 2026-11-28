import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/library_rows/folder_as_row.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/library_migration.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/migrations/hidden_folder_repair.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/sqlite_storage.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../library_rows/library_sources.dart';
import 'aged_summaries.dart';
import 'hive_scratch.dart';
import 'tile_parity.dart';

const corpusVariable = 'ICARUS_LIBRARY_CORPUS';
const scratchVariable = 'ICARUS_LIBRARY_SCRATCH';
const syntheticVariable = 'ICARUS_SYNTHETIC_LIBRARY_OUT';
const syntheticCountVariable = 'ICARUS_SYNTHETIC_LIBRARY_COUNT';
const costVariable = 'ICARUS_LIBRARY_COPY_COST';
const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

Future<Directory> _scratchCopyOf(Directory store, Directory scratchRoot) async {
  final scratch = await scratchRoot.createTemp('store-');
  for (final file in store.listSync().whereType<File>()) {
    if (path.extension(file.path) == '.hive') {
      await file.copy(path.join(scratch.path, path.basename(file.path)));
    }
  }
  return scratch;
}

Future<void> _startAsTheAppDoes(Directory scratch) async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_pathProvider, (_) async => scratch.path);
  await openScratchHive(scratch);
  await StrategyMigrator.migrateAllStrategies();
  await moveOrphansToTopLevel();
}

List<Directory> storesIn(String corpus) {
  final stores = hiveStoresUnder(Directory(corpus));
  expect(stores, isNotEmpty, reason: '$corpusVariable names $corpus');
  return stores;
}

Future<(List<StrategyData>, List<Folder>)> corpusLibrary(
  List<Directory> stores,
  Directory scratchRoot, {
  String round = '',
}) async {
  final strategies = <StrategyData>[];
  final folders = <Folder>[];
  for (final store in stores) {
    final scratch = await _scratchCopyOf(store, scratchRoot);
    try {
      await _startAsTheAppDoes(scratch);
      final label =
          path.relative(store.path, from: Platform.environment[corpusVariable]);
      String renamed(String id) =>
          const Uuid().v5(Namespace.url.value, '$round$label/$id');
      for (final strategy
          in Hive.box<StrategyData>(HiveBoxNames.strategiesBox).values) {
        strategies.add(
          strategy.copyWith(
            id: renamed(strategy.id),
            folderID:
                strategy.folderID == null ? null : renamed(strategy.folderID!),
          ),
        );
      }
      for (final folder in Hive.box<Folder>(HiveBoxNames.foldersBox).values) {
        folders.add(
          Folder(
            name: folder.name,
            id: renamed(folder.id),
            dateCreated: folder.dateCreated,
            iconId: folder.iconId,
            color: folder.color,
            parentID:
                folder.parentID == null ? null : renamed(folder.parentID!),
            customColor: folder.customColor,
          ),
        );
      }
    } finally {
      await Hive.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_pathProvider, null);
      await scratch.delete(recursive: true);
    }
  }
  expect(strategies, isNotEmpty, reason: 'the corpus holds no strategy');
  return (strategies, folders);
}

Future<void> _writeHiveLibrary(
  Directory out,
  Iterable<StrategyData> strategies,
  Iterable<Folder> folders,
) async {
  await out.create(recursive: true);
  Hive.init(out.path);
  final strategyBox =
      await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
  final folderBox = await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
  for (final strategy in strategies) {
    await strategyBox.put(strategy.id, strategy.copyWith());
  }
  for (final folder in folders) {
    await folderBox.put(folder.id, folder);
  }
  await Hive.close();
}

Future<(Duration, int, int)> _timedOpen(File file) async {
  final engine = SqliteEngine(file.path);
  final clock = Stopwatch()..start();
  final store = await openStoreOn(engine);
  final took = clock.elapsed;
  final rebuilt = store.summariesRebuiltAtOpen;
  final listed = switch (store.library) {
    LibraryOpen(:final list) => list.strategies
        .where((summary) => summary.agentsInOrder.isNotEmpty)
        .length,
    LibraryShut(:final failure) => fail('$failure'),
  };
  await store.close();
  await engine.close();
  return (took, listed, rebuilt);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    appProviderContainer = ProviderContainer();
    if (!Hive.isAdapterRegistered(20)) registerIcarusAdapters(Hive);
  });
  tearDownAll(() => appProviderContainer.dispose());

  final corpus = Platform.environment[corpusVariable];
  final scratchRoot = Directory(
    Platform.environment[scratchVariable] ?? Directory.systemTemp.path,
  );

  test(
    'a synthetic library of 700 strategies from the corpus, or as many as '
    '$syntheticCountVariable says, is written as a Hive store',
    skip: corpus == null || Platform.environment[syntheticVariable] == null
        ? '$corpusVariable and $syntheticVariable name the corpus and the folder to write'
        : false,
    timeout: const Timeout(Duration(hours: 1)),
    () async {
      final (strategies, folders) = await corpusLibrary(
        storesIn(corpus!),
        scratchRoot,
      );
      await _writeHiveLibrary(
        Directory(Platform.environment[syntheticVariable]!),
        strategies.take(
          int.parse(Platform.environment[syntheticCountVariable] ?? '700'),
        ),
        folders,
      );
    },
  );

  test(
    'every corpus strategy\'s store summary shows what main\'s tile shows',
    skip: corpus == null
        ? '$corpusVariable names a folder of Hive stores'
        : false,
    timeout: const Timeout(Duration(hours: 1)),
    () async {
      final (strategies, folders) = await corpusLibrary(
        storesIn(corpus!),
        scratchRoot,
      );
      final store = await openStoreOn(MemoryEngine(MemoryStorage()));
      final folderRows = [for (final folder in folders) folderToRow(folder)];
      final unplaced = [...folderRows];
      while (unplaced.isNotEmpty) {
        final placed = {
          for (final row in folderRows)
            if (!unplaced.contains(row)) row.publicId,
        };
        final ready = [
          for (final row in unplaced)
            if (row.parentFolderPublicId == null ||
                placed.contains(row.parentFolderPublicId))
              row,
        ];
        expect(ready, isNotEmpty, reason: 'folders that loop');
        expect(
          await store.editLibrary([for (final row in ready) PutFolder(row)]),
          isA<Saved<LibraryEdited, LibraryRefusal>>(),
        );
        unplaced.removeWhere(ready.contains);
      }
      final refused = <String>[];
      final kept = <StrategyData>[];
      for (final strategy in strategies) {
        switch (strategyToRows(strategyAsHiveHoldsIt(strategy))) {
          case StrategyRowsRefused(:final problems):
            refused.add('${strategy.id}: $problems');
          case StrategyRowsMade(:final rows):
            expect(
              await store.putStrategy(rows),
              isA<Saved<LibraryEdited, LibraryRefusal>>(),
              reason: strategy.id,
            );
            kept.add(strategy);
        }
      }
      final summaries = switch (store.library) {
        LibraryOpen(:final list) => {
            for (final summary in list.strategies) summary.publicId: summary,
          },
        LibraryShut(:final failure) => fail('$failure'),
      };
      var same = 0;
      var groupOrder = 0;
      var pageOrder = 0;
      final differing = <String>[];
      for (final strategy in kept) {
        switch (tileParity(summaries[strategy.id]!, strategy)) {
          case TileSame():
            same++;
          case TileInGroupOrder():
            groupOrder++;
          case TileInPageOrder():
            pageOrder++;
          case final TileDiffers differs:
            differing.add('${strategy.id}: $differs');
        }
      }
      await store.close();
      debugPrint('${strategies.length} corpus strategies, '
          '${kept.length} compared: $same show what main\'s tile shows, '
          '$groupOrder differ only in lineup group order, $pageOrder only '
          'because their saved page list is out of sort order; '
          '${refused.length} refused by the converter: $refused');
      expect(differing, isEmpty, reason: differing.take(3).join('\n'));
      expect(refused, isEmpty);
      expect(same + groupOrder + pageOrder, strategies.length);
    },
  );

  test(
    'opening 700 strategies whose summaries an older build wrote rebuilds '
    'them all, and how long it takes',
    skip: corpus == null || Platform.environment[costVariable] == null
        ? '$corpusVariable names the corpus and $costVariable asks for this'
        : false,
    timeout: const Timeout(Duration(hours: 1)),
    () async {
      final (strategies, folders) = await corpusLibrary(
        storesIn(corpus!),
        scratchRoot,
      );
      final scratch = await scratchRoot.createTemp('summary-rebuild-');
      try {
        await _writeHiveLibrary(scratch, strategies.take(700), folders);
        await openScratchHive(scratch);
        final file = libraryStoreFile(scratch.path);
        await file.parent.create(recursive: true);
        final engine = SqliteEngine(file.path);
        final store = await openStoreOn(engine);
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
        await store.close();
        await engine.close();
        final (current, _, _) = await _timedOpen(file);
        final aging = SqliteEngine(file.path);
        final aged = await ageSummaries(aging);
        await aging.close();
        final (rebuilding, withAgents, rebuilt) = await _timedOpen(file);
        final (again, _, rebuiltAgain) = await _timedOpen(file);
        debugPrint('700 strategies: open with current summaries '
            '${current.inMilliseconds} ms; with $aged summaries from the '
            'build before, ${rebuilding.inMilliseconds} ms '
            '($withAgents now list agents in order); the open after that, '
            'with nothing written in between, ${again.inMilliseconds} ms, '
            'rebuilding $rebuiltAgain');
        expect(aged, 700);
        expect(rebuilt, 700);
      } finally {
        await Hive.close();
        await scratch.delete(recursive: true);
      }
    },
  );
}
