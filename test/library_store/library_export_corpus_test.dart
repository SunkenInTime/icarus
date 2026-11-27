import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_store/library_migration.dart';
import 'package:icarus/library_store/library_migration_start.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/library_store/store_library.dart';
import 'package:icarus/migrations/hidden_folder_repair.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/services/archive_manifest.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:path/path.dart' as path;

import '../library_rows/library_sources.dart';
import 'hive_scratch.dart';

const corpusVariable = 'ICARUS_LIBRARY_CORPUS';
const scratchVariable = 'ICARUS_LIBRARY_SCRATCH';
const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

final class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

final class _Totals {
  int stores = 0;
  int strategies = 0;
  int sameExport = 0;
  int sameAfterImport = 0;
  int keyedOtherwise = 0;
  int changedByImport = 0;
  int sideFromAnotherPage = 0;
  final problems = <String>[];

  String render() => [
        'Hive stores: $stores, strategies: $strategies',
        'backups from the store the same as from Hive: $sameExport',
        'store backups imported into a new store and backed up again the '
            'same as Hive backups imported into Hive and backed up again: '
            '$sameAfterImport',
        'libraries whose backup, imported and backed up again, is not the '
            'backup it came from, on Hive as on the store (#844): '
            '$changedByImport',
        'Hive records under a key that is not their id: $keyedOtherwise',
        'strategies whose first stored page is not their first page, so '
            'their tile could show another side: $sideFromAnotherPage',
        'problems: ${problems.isEmpty ? 'none' : problems.length}',
        ...problems,
      ].join('\n');
}

Object? _strategyJson(Object? json) => switch (json) {
      final Map<String, Object?> strategy => {
          for (final MapEntry(:key, :value) in strategy.entries)
            if (key != 'id') key: value,
        },
      _ => json,
    };

Object? _described(File file) {
  final name = path.basename(file.path);
  if (name == archiveMetadataFileName) {
    final manifest = {
      ...jsonDecode(file.readAsStringSync()) as Map<String, Object?>,
    }..remove('exportedAt');
    final ids = <String, String>{};
    String label(Object? id) =>
        ids.putIfAbsent(id as String, () => 'folder ${ids.length + 1}');
    return {
      ...manifest,
      'folders': [
        for (final folder in manifest['folders'] as List)
          {
            ...folder as Map<String, Object?>,
            'manifestId': label(folder['manifestId']),
            if (folder['parentManifestId'] case final parent?)
              'parentManifestId': label(parent),
          },
      ],
      'strategies': [
        for (final strategy in manifest['strategies'] as List)
          {
            ...strategy as Map<String, Object?>,
            if (strategy['folderManifestId'] case final folder?)
              'folderManifestId': label(folder),
          },
      ],
    };
  }
  if (path.extension(name) != '.ica') return 'file';
  final archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
  return {
    for (final entry
        in archive.files.toList()..sort((a, b) => a.name.compareTo(b.name)))
      entry.name: path.extension(entry.name) == '.json'
          ? _strategyJson(jsonDecode(utf8.decode(entry.content as List<int>)))
          : (entry.content as List<int>).length,
  };
}

String _tree(Directory root) => jsonEncode({
      for (final file
          in root.listSync(recursive: true).whereType<File>().toList()
            ..sort((a, b) => a.path.compareTo(b.path)))
        path.posix
                .joinAll(path.split(path.relative(file.path, from: root.path))):
            _described(file),
    });

Future<Directory> _scratchCopyOf(Directory store, Directory root) async {
  final scratch = await root.createTemp('store-');
  for (final file in store.listSync().whereType<File>()) {
    if (path.extension(file.path) == '.hive') {
      await file.copy(path.join(scratch.path, path.basename(file.path)));
    }
  }
  return scratch;
}

Future<void> _openTheRest() async {
  await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
  await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
  await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
  await Hive.openBox<int>(HiveBoxNames.pinnedItemsBox);
  await MapThemeProfilesProvider.bootstrap();
}

void _useSupport(Directory directory) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, (_) async => directory.path);

Future<String> _backup(ProviderContainer container, File into) async {
  final staging = await StrategyImportExportService(container)
      .buildLibraryExportDirectoryForTest();
  try {
    final encoder = ZipFileEncoder()..create(into.path);
    await encoder.addDirectory(staging, includeDirName: false);
    await encoder.close();
    return _tree(staging);
  } finally {
    await staging.delete(recursive: true);
  }
}

Future<void> _oneStore(Directory store, Directory root, _Totals totals) async {
  final label =
      path.relative(store.path, from: Platform.environment[corpusVariable]);
  void problem(String what) => totals.problems.add('$label: $what');
  final container = ProviderContainer(
    overrides: [authProvider.overrideWith(_SignedOut.new)],
  );

  final onHive = await _scratchCopyOf(store, root);
  final String fromHive;
  final String hiveAgain;
  try {
    _useSupport(onHive);
    await openScratchHive(onHive);
    await _openTheRest();
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    for (final key in box.keys) {
      final strategy = box.get(key)!;
      if ('$key' != strategy.id) totals.keyedOtherwise++;
      if (strategy.pages.isNotEmpty) {
        final byPosition = [...strategy.pages]
          ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
        if (byPosition.first.isAttack != strategy.pages.first.isAttack) {
          totals.sideFromAnotherPage++;
        }
      }
    }
    final folders = Hive.box<Folder>(HiveBoxNames.foldersBox);
    totals.keyedOtherwise +=
        folders.keys.where((key) => '$key' != folders.get(key)!.id).length;
    await StrategyMigrator.migrateAllStrategies();
    await moveOrphansToTopLevel();
    totals
      ..stores += 1
      ..strategies += box.length;
    final hiveBackup = File(path.join(onHive.path, 'h.zip'));
    fromHive = await _backup(container, hiveBackup);
    await box.clear();
    await folders.clear();
    await StrategyImportExportService(container)
        .loadFromFileDrop([XFile(hiveBackup.path)]);
    hiveAgain =
        await _backup(container, File(path.join(onHive.path, 'h2.zip')));
    if (hiveAgain != fromHive) totals.changedByImport++;
  } finally {
    await Hive.close();
  }

  final onStore = await _scratchCopyOf(store, root);
  final storeBackup = File(path.join(root.path,
      '${onStore.uri.pathSegments.where((s) => s.isNotEmpty).last}.zip'));
  try {
    _useSupport(onStore);
    await openScratchHive(onStore);
    await _openTheRest();
    final starting = ProviderContainer();
    await openLibraryOnStore(
      starting,
      LibraryStoreLaunch.parse(
        const [LibraryStoreLaunch.storeFlag],
        mayShadow: true,
      ),
      hiveDirectory: onStore.path,
      allowsLocalLibrary: true,
      build: '',
      bringUpToDate: () async {},
      servedAgain: () {},
    );
    if (starting.read(libraryOnStoreProvider)
        case final LibraryNotServed notServed) {
      problem('the library was not served: ${notServed.why}');
      await starting.read(libraryStoreProvider.notifier).close();
      starting.dispose();
      return;
    }
    await StrategyMigrator.migrateAllStrategies();
    await moveOrphansToTopLevel();
    final fromStore = await _backup(container, storeBackup);
    if (fromStore == fromHive) {
      totals.sameExport++;
    } else {
      problem('the store backup differs from the Hive backup');
    }
    await starting.read(libraryStoreProvider.notifier).close();
    starting.dispose();

    final fresh = await _open(MemoryEngine(MemoryStorage()));
    try {
      expect(
        await migrateLibraryIntoStore(fresh, strategies: [], folders: []),
        isA<MigrationFinishedNow>(),
      );
      LocalLibrary.source = switch (await StoreLibrary.load(
        fresh,
        lost: (why) => problem('the new store was lost: $why'),
      )) {
        StoreLibraryLoaded(:final library) => LibraryInStore(library),
        StoreLibraryNotLoaded(:final why) => throw StateError(why),
      };
      final imported = await StrategyImportExportService(container)
          .loadFromFileDrop([XFile(storeBackup.path)]);
      if (imported.issues.isNotEmpty) {
        problem('the store backup imported with ${imported.issues}');
      }
      final again = await _backup(
        container,
        File(
            path.join(root.path, 'again-${storeBackup.uri.pathSegments.last}')),
      );
      if (again == hiveAgain) {
        totals.sameAfterImport++;
      } else {
        problem(
          'the store backup imported into a new store and backed up again '
          'differs from the Hive backup imported into Hive and backed up again',
        );
      }
    } finally {
      await fresh.close();
    }
  } finally {
    LocalLibrary.source = const LibraryInHive();
    container.dispose();
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null);
    await onHive.delete(recursive: true);
    await onStore.delete(recursive: true);
  }
}

Future<LibraryStore> _open(StorageEngine engine) async =>
    switch (await LibraryStore.open(engine, canRead: appCanRead)) {
      StoreOpened(:final store) => store,
      StoreNotOpened(:final problem) => throw StateError('$problem'),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final corpus = Platform.environment[corpusVariable];
  setUpAll(() => appProviderContainer = ProviderContainer());
  tearDownAll(() => appProviderContainer.dispose());

  test(
    'every corpus library backs up from the store as it backs up from Hive, '
    'and the store backup imported into a new store backs up again as the '
    'Hive backup imported into Hive does',
    () async {
      final root = Directory(
        Platform.environment[scratchVariable] ?? Directory.systemTemp.path,
      );
      final scratchRoot = await root.createTemp('library-export-');
      final totals = _Totals();
      try {
        final stores = hiveStoresUnder(Directory(corpus!));
        expect(stores, isNotEmpty, reason: '$corpusVariable names $corpus');
        for (final store in stores) {
          await _oneStore(store, scratchRoot, totals);
        }
      } finally {
        await scratchRoot.delete(recursive: true);
      }
      debugPrint(totals.render());
      expect(totals.problems, isEmpty);
      expect(totals.sameExport, totals.stores);
      expect(totals.sameAfterImport, totals.stores);
    },
    skip: corpus == null
        ? 'set $corpusVariable to a folder of Hive stores'
        : false,
    timeout: Timeout.none,
  );
}
