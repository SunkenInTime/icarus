import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/folder_as_row.dart';
import 'package:icarus/library_rows/strategy_comparison.dart';
import 'package:icarus/library_store/canvas_units.dart';
import 'package:icarus/library_store/library_migration.dart';
import 'package:icarus/library_store/library_migration_start.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/library_store/stored_strategy.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:path/path.dart' as path;

import '../library_rows/library_sources.dart';
import 'hive_scratch.dart';

const corpusVariable = 'ICARUS_LIBRARY_CORPUS';
const scratchVariable = 'ICARUS_LIBRARY_SCRATCH';
const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

final class _Totals {
  int stores = 0;
  int strategies = 0;
  int pages = 0;
  int folders = 0;
  int same = 0;
  int sameAsideFromLineupOrder = 0;
  int tiesBroken = 0;
  int sameFolders = 0;
  int finishedOnSecondStart = 0;
  final leftBehind = <String, int>{};
  final differences = <String, int>{};
  final problems = <String>[];

  void count(Map<String, int> into, String key) =>
      into[key] = (into[key] ?? 0) + 1;

  String render() => [
        'Hive stores: $stores, strategies: $strategies, pages: $pages, '
            'folders: $folders',
        'read back the same as the Hive record the app shows: $same; the same '
            'with lineups in group order: $sameAsideFromLineupOrder',
        'strategies whose tied pages were put in their shown order: '
            '$tiesBroken',
        'folders the same: $sameFolders',
        'left behind: ${leftBehind.isEmpty ? 'none' : leftBehind}',
        'differences by kind: ${differences.isEmpty ? 'none' : differences}',
        'finished and untouched on a second start: $finishedOnSecondStart',
        'problems: ${problems.isEmpty ? 'none' : problems.length}',
        ...problems,
      ].join('\n');
}

Future<Directory> _scratchCopyOf(Directory store, Directory root) async {
  final scratch = await root.createTemp('store-');
  for (final file in store.listSync().whereType<File>()) {
    if (path.extension(file.path) == '.hive') {
      await file.copy(path.join(scratch.path, path.basename(file.path)));
    }
  }
  return scratch;
}

void _useSupportDirectory(Directory directory) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, (_) async => directory.path);

Future<({Map<String, StrategyData> strategies, Map<String, Folder> folders})>
    _asTheAppShowsIt(Directory store, Directory root) async {
  final scratch = await _scratchCopyOf(store, root);
  try {
    _useSupportDirectory(scratch);
    await openScratchHive(scratch);
    await StrategyMigrator.migrateAllStrategies();
    return (
      strategies: {
        for (final strategy
            in Hive.box<StrategyData>(HiveBoxNames.strategiesBox).values)
          strategy.id: cloneStrategy(strategy),
      },
      folders: {
        for (final folder in Hive.box<Folder>(HiveBoxNames.foldersBox).values)
          folder.id: folder,
      },
    );
  } finally {
    await Hive.close();
    await scratch.delete(recursive: true);
  }
}

String _kindOf(StrategyDifference difference) => '${difference.kind.name} '
    '${difference.path.replaceAll(RegExp(r'\[\d+\]'), '[]')}';

Future<void> _moveOne(Directory store, Directory root, _Totals totals) async {
  final label =
      path.relative(store.path, from: Platform.environment[corpusVariable]);
  void problem(String what) => totals.problems.add('$label: $what');
  final shown = await _asTheAppShowsIt(store, root);
  final scratch = await _scratchCopyOf(store, root);
  final launch = LibraryStoreLaunch.parse(
    const [LibraryStoreLaunch.storeFlag],
    mayShadow: true,
  );
  try {
    _useSupportDirectory(scratch);
    await openScratchHive(scratch);
    final writes = await HiveWrites.watch(scratch);
    final container = ProviderContainer();
    await moveLibraryIntoStore(
      container,
      launch,
      hiveDirectory: scratch.path,
      allowsLocalLibrary: true,
      build: '',
    );
    final atStart = container.read(libraryMigrationProvider)!;
    totals
      ..stores += 1
      ..strategies += shown.strategies.length
      ..pages += shown.strategies.values
          .fold(0, (sum, strategy) => sum + strategy.pages.length)
      ..folders += shown.folders.length;

    final MigrationFinished record;
    switch (atStart.migration) {
      case MigrationFinishedNow(record: final finished):
        record = finished;
      case final other:
        problem('the move did not finish: $other');
        return;
    }
    final store = switch (container.read(libraryStoreProvider)) {
      LibraryStoreReady(:final store) => store,
      final other => throw StateError('$other'),
    };
    final left = {for (final entry in record.strategies) entry.publicId};
    for (final entry in [...record.strategies, ...record.folders]) {
      totals.count(totals.leftBehind, entry.reason.split(':').first);
    }
    for (final MapEntry(key: id, value: expected) in shown.strategies.entries) {
      if (left.contains(id)) {
        if (Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
            .values
            .every((strategy) => strategy.id != id)) {
          problem('left behind $id and it is not in Hive');
        }
        continue;
      }
      final StrategyData back;
      switch (await readStoredRows(store, id)) {
        case StoredRowsRead(:final rows):
          switch (strategyOfRows(rows)) {
            case StoredAsData(:final strategy):
              back = strategy;
            case final other:
              problem('$id reads back as $other');
              continue;
          }
        case StoredRowsNot(:final stored):
          problem('$id is not in the store: $stored');
          continue;
      }
      final inShownOrder = pagesInTheirShownOrder(expected);
      if (!identical(inShownOrder, expected)) totals.tiesBroken += 1;
      final differences = strategyDifferences(inShownOrder, back);
      final real = [
        for (final difference in differences)
          if (difference.kind != DifferenceKind.lineupOrder) difference,
      ];
      if (differences.isEmpty) {
        totals.same += 1;
      } else if (real.isEmpty) {
        totals.sameAsideFromLineupOrder += 1;
      }
      for (final difference in real) {
        totals.count(totals.differences, _kindOf(difference));
      }
    }

    final rows = switch (store.library) {
      LibraryOpen(:final list) => {
          for (final row in list.folders) row.publicId: row,
        },
      LibraryShut(:final failure) => throw StateError('$failure'),
    };
    for (final MapEntry(key: id, value: folder) in shown.folders.entries) {
      final row = rows[id];
      final expected = folderToRow(folder);
      if (row
          case ReadableFolder(
            :final name,
            :final parentFolderPublicId,
            :final iconId,
            :final color,
            :final customColorValue,
          )
          when name == expected.name &&
              parentFolderPublicId == expected.parentFolderPublicId &&
              iconId == expected.iconId &&
              color == expected.color &&
              customColorValue == expected.customColorValue) {
        totals.sameFolders += 1;
      } else if (record.folders.every((entry) => entry.publicId != id)) {
        problem('folder $id reads back as $row');
      }
    }

    await container.read(libraryStoreProvider.notifier).close();
    container.dispose();
    for (final write in await writes.stop()) {
      problem(write);
    }

    final again = ProviderContainer();
    await moveLibraryIntoStore(
      again,
      launch,
      hiveDirectory: scratch.path,
      allowsLocalLibrary: true,
      build: '',
    );
    if (again.read(libraryMigrationProvider)!.migration
        is MigrationWasFinished) {
      totals.finishedOnSecondStart += 1;
    } else {
      problem('a second start did not find the move finished');
    }
    await again.read(libraryStoreProvider.notifier).close();
    again.dispose();
  } finally {
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null);
    await scratch.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final corpus = Platform.environment[corpusVariable];

  test(
    'every corpus library, as the last build left it on disk, moves into the '
    'store: each strategy reads back as the Hive record the app shows, '
    'lineup order aside, folders too, Hive is never written, and a second '
    'start touches nothing',
    () async {
      final root = Directory(
        Platform.environment[scratchVariable] ?? Directory.systemTemp.path,
      );
      final scratchRoot = await root.createTemp('library-migration-');
      final totals = _Totals();
      try {
        final stores = hiveStoresUnder(Directory(corpus!));
        expect(stores, isNotEmpty, reason: '$corpusVariable names $corpus');
        for (final store in stores) {
          await _moveOne(store, scratchRoot, totals);
        }
      } finally {
        await scratchRoot.delete(recursive: true);
      }
      debugPrint(totals.render());
      expect(totals.problems, isEmpty);
      expect(totals.differences, isEmpty);
      expect(totals.finishedOnSecondStart, totals.stores);
    },
    skip: corpus == null
        ? 'set $corpusVariable to a folder of Hive stores'
        : false,
    timeout: Timeout.none,
  );
}
