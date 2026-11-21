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
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/shadow_copy.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/library_store/library_box_writes.dart';
import 'package:icarus/library_store/store_check.dart';
import 'package:icarus/migrations/hidden_folder_repair.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/sqlite_storage.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../library_rows/library_sources.dart';
import 'hive_scratch.dart';

const corpusVariable = 'ICARUS_LIBRARY_CORPUS';
const scratchVariable = 'ICARUS_LIBRARY_SCRATCH';
const syntheticVariable = 'ICARUS_SYNTHETIC_LIBRARY_OUT';
const costVariable = 'ICARUS_LIBRARY_COPY_COST';
const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

final class CorpusTotals {
  int stores = 0;
  int strategies = 0;
  int pages = 0;
  int folders = 0;
  int copied = 0;
  int same = 0;
  int sameFolders = 0;
  int unchangedOnSecondStart = 0;
  int hiveBytes = 0;
  int storeBytes = 0;
  var copyTime = Duration.zero;
  var checkTime = Duration.zero;
  var slowestStore = Duration.zero;
  final problems = <String>[];

  String render() => [
        'Hive stores: $stores, strategies: $strategies, pages: $pages, '
            'folders: $folders',
        'copied: $copied, the same after reading back: $same strategies, '
            '$sameFolders folders',
        'unchanged on a second start: $unchangedOnSecondStart',
        'Hive files: $hiveBytes bytes, store files: $storeBytes bytes',
        'copy: ${copyTime.inMilliseconds} ms, check: '
            '${checkTime.inMilliseconds} ms, slowest store: '
            '${slowestStore.inMilliseconds} ms',
        'problems: ${problems.isEmpty ? 'none' : problems.length}',
        ...problems,
      ].join('\n');
}

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
  await moveOrphansToTopLevel(
    Hive.box<Folder>(HiveBoxNames.foldersBox),
    Hive.box<StrategyData>(HiveBoxNames.strategiesBox),
  );
}

Future<LibraryStore> _openSqlite(SqliteEngine engine) => openStoreOn(engine);

int _bytesOf(Directory directory, bool Function(File file) which) => directory
    .listSync(recursive: true)
    .whereType<File>()
    .where(which)
    .fold(0, (sum, file) => sum + file.lengthSync());

Future<void> _checkOne(
  Directory store,
  Directory scratchRoot,
  CorpusTotals totals,
) async {
  final label =
      path.relative(store.path, from: Platform.environment[corpusVariable]);
  final scratch = await _scratchCopyOf(store, scratchRoot);
  final clock = Stopwatch()..start();
  try {
    await _startAsTheAppDoes(scratch);
    final hive = hiveLibraryNow();
    totals
      ..stores += 1
      ..strategies += hive.strategies.length
      ..pages += hive.strategies.fold(0, (sum, s) => sum + s.pages.length)
      ..folders += hive.folders.length;
    final writes = await HiveWrites.watch(scratch);
    final file = libraryStoreFile(scratch.path);
    await file.parent.create(recursive: true);

    final engine = SqliteEngine(file.path);
    final first = await _openSqlite(engine);
    final copyClock = Stopwatch()..start();
    final copy = await copyFromHive(first);
    totals.copyTime += copyClock.elapsed;
    final checkClock = Stopwatch()..start();
    final check = await checkFromHive(first);
    totals.checkTime += checkClock.elapsed;
    await first.close();
    await engine.close();

    final again = SqliteEngine(file.path);
    final second = await _openSqlite(again);
    final secondCopy = await copyFromHive(second);
    final secondCheck = await checkFromHive(second);
    await second.close();
    await again.close();

    totals
      ..copied += copy.strategies.whereType<StrategyCopied>().length
      ..unchangedOnSecondStart +=
          secondCopy.strategies.whereType<StrategyUnchanged>().length
      ..hiveBytes += _bytesOf(scratch, (f) => path.extension(f.path) == '.hive')
      ..storeBytes += _bytesOf(file.parent, (f) => true);
    void problem(String what) => totals.problems.add('$label: $what');
    if (copy case ShadowCopyStopped(:final stop))
      problem('copy stopped: $stop');
    for (final result in copy.strategies) {
      if (result case StrategyNotMirrored(:final strategyId, :final reason)) {
        problem('not copied $strategyId: $reason');
      }
    }
    for (final result in copy.folders) {
      if (result case FolderNotCopied(:final folderId, :final reason)) {
        problem('folder not copied $folderId: $reason');
      }
    }
    for (final (round, result) in [('first', check), ('second', secondCheck)]) {
      switch (result) {
        case StoreNotChecked(:final failure):
          problem('$round check failed: $failure');
        case final StoreChecked checked:
          if (round == 'first') {
            totals
              ..same += checked.sameStrategies
              ..sameFolders += checked.sameFolders;
          }
          if (!checked.isExact) {
            problem('$round check: ${checked.strategyProblems} '
                '${checked.folderProblems} ${checked.unplaced.length} unplaced');
          }
      }
    }
    if (secondCopy.strategies.any((s) => s is! StrategyUnchanged) ||
        secondCopy.folders.any((f) => f is! FolderUnchanged)) {
      problem('the second start changed something');
    }
    for (final write in await writes.stop()) {
      problem(write);
    }
  } finally {
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null);
    await scratch.delete(recursive: true);
    if (clock.elapsed > totals.slowestStore)
      totals.slowestStore = clock.elapsed;
  }
}

Future<(List<StrategyData>, List<Folder>)> _corpusLibrary(
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
    await folderBox.put(folder.id, folderAsHiveHoldsIt(folder));
  }
  await Hive.close();
}

Future<String> _copyCost(
  int size,
  List<StrategyData> strategies,
  List<Folder> folders,
  Directory scratchRoot,
) async {
  final scratch = await scratchRoot.createTemp('cost-$size-');
  try {
    await _writeHiveLibrary(scratch, strategies.take(size), folders);
    await openScratchHive(scratch);
    final file = libraryStoreFile(scratch.path);
    await file.parent.create(recursive: true);
    final engine = SqliteEngine(file.path);
    final store = await _openSqlite(engine);
    final clock = Stopwatch()..start();
    final copy = await copyFromHive(store);
    final took = clock.elapsed;
    await store.close();
    await engine.close();
    expect(copy.strategies.whereType<StrategyCopied>(), hasLength(size));
    final inMemory = await openStoreOn(MemoryEngine(MemoryStorage()));
    final memoryClock = Stopwatch()..start();
    await copyFromHive(inMemory);
    final memoryTook = memoryClock.elapsed;
    await inMemory.close();
    String each(Duration total) =>
        (total.inMicroseconds / size / 1000).toStringAsFixed(1);
    return '$size strategies: SQLite ${took.inMilliseconds} ms '
        '(${each(took)} ms each), memory engine ${memoryTook.inMilliseconds} '
        'ms (${each(memoryTook)} ms each)';
  } finally {
    await Hive.close();
    await scratch.delete(recursive: true);
  }
}

Future<List<String>> _editEachThroughMirror(
  Directory store,
  Directory scratchRoot,
) async {
  final label =
      path.relative(store.path, from: Platform.environment[corpusVariable]);
  final scratch = await _scratchCopyOf(store, scratchRoot);
  final problems = <String>[];
  try {
    await _startAsTheAppDoes(scratch);
    final file = libraryStoreFile(scratch.path);
    await file.parent.create(recursive: true);
    final engine = SqliteEngine(file.path);
    final opened = await _openSqlite(engine);
    final mirror = StoreMirror(readHive: hiveLibraryNow, breathe: () async {});
    LocalLibrary.follower = mirror;
    final writes = LibraryBoxWrites();
    await mirror.copyThenFollow(opened, writes: writes);
    await writes.stop();
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    for (final stored in box.values.toList()) {
      final saved = await const LocalLibrary()
          .renameStrategy(stored, '${stored.name} edited');
      if (saved is! LibraryWritten) problems.add('$label: not saved $saved');
    }
    await mirror.drained();
    final check = await checkStoreAgainstHive(
      hiveLibraryNow(),
      opened,
      foreignNames: const [],
      breathe: () async {},
      strategiesRefused: mirror.refusedStrategies,
      foldersRefused: mirror.refusedFolders,
    );
    switch (check) {
      case StoreNotChecked(:final failure):
        problems.add('$label: check failed $failure');
      case final StoreChecked checked when !checked.isExact:
        problems.add(
          '$label: ${checked.strategyProblems} ${checked.folderProblems}',
        );
      case StoreChecked():
        break;
    }
    await opened.close();
    await engine.close();
  } finally {
    LocalLibrary.follower = null;
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null);
    await scratch.delete(recursive: true);
  }
  return problems;
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
    'every Hive store in the corpus is copied into a SQLite store, reads back the same, and no Hive file changes',
    skip: corpus == null
        ? '$corpusVariable names a folder of Hive stores'
        : false,
    timeout: const Timeout(Duration(hours: 2)),
    () async {
      final totals = CorpusTotals();
      for (final store in hiveStoresUnder(Directory(corpus!))) {
        await _checkOne(store, scratchRoot, totals);
      }
      debugPrint(totals.render());
      expect(totals.strategies, greaterThan(0));
      expect(totals.problems, isEmpty);
      expect(totals.same, totals.strategies);
    },
  );

  test(
    'a synthetic library of 700 strategies from the corpus is written as a Hive store',
    skip: corpus == null || Platform.environment[syntheticVariable] == null
        ? '$corpusVariable and $syntheticVariable name the corpus and the folder to write'
        : false,
    timeout: const Timeout(Duration(hours: 1)),
    () async {
      final (strategies, folders) = await _corpusLibrary(
        hiveStoresUnder(Directory(corpus!)),
        scratchRoot,
      );
      await _writeHiveLibrary(
        Directory(Platform.environment[syntheticVariable]!),
        strategies.take(700),
        folders,
      );
    },
  );

  test(
    'the copy\'s cost at 100, 350, 700 and 1,400 strategies from the corpus',
    skip: corpus == null || Platform.environment[costVariable] == null
        ? '$corpusVariable names the corpus and $costVariable asks for this'
        : false,
    timeout: const Timeout(Duration(hours: 2)),
    () async {
      final stores = hiveStoresUnder(Directory(corpus!));
      final (first, firstFolders) = await _corpusLibrary(stores, scratchRoot);
      final (second, secondFolders) =
          await _corpusLibrary(stores, scratchRoot, round: 'second/');
      final strategies = [...first, ...second];
      final folders = [...firstFolders, ...secondFolders];
      for (final size in [100, 350, 700, 1400]) {
        debugPrint(await _copyCost(size, strategies, folders, scratchRoot));
      }
    },
  );

  test(
    'every Hive store in the corpus, with every strategy renamed through LocalLibrary while the store mirrors saves, leaves the store exact',
    skip: corpus == null
        ? '$corpusVariable names a folder of Hive stores'
        : false,
    timeout: const Timeout(Duration(hours: 2)),
    () async {
      final problems = <String>[];
      var stores = 0;
      for (final store in hiveStoresUnder(Directory(corpus!))) {
        stores++;
        problems.addAll(await _editEachThroughMirror(store, scratchRoot));
      }
      debugPrint('stores edited through the mirror: $stores; problems: '
          '${problems.isEmpty ? 'none' : problems.join('\n')}');
      expect(problems, isEmpty);
    },
  );
}
