import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:path/path.dart' as path;

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

final class LoadedLibrary {
  const LoadedLibrary({required this.strategies, required this.folders});

  final List<StrategyData> strategies;
  final List<Folder> folders;
}

Future<Directory> _openScratchHive(String label) async {
  final directory = await Directory.systemTemp.createTemp('icarus-$label-');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_pathProvider, (_) async => directory.path);
  Hive.init(directory.path);
  if (!Hive.isAdapterRegistered(20)) registerIcarusAdapters(Hive);
  return directory;
}

Future<void> _closeScratchHive(Directory directory) async {
  await Hive.close();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_pathProvider, null);
  await directory.delete(recursive: true);
}

Future<LoadedLibrary> loadHiveStore(Directory store) async {
  final directory = await _openScratchHive('library-store');
  try {
    for (final file in store.listSync().whereType<File>()) {
      if (path.extension(file.path) == '.hive') {
        await file.copy(path.join(directory.path, path.basename(file.path)));
      }
    }
    final strategies =
        await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    final folders = await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    return LoadedLibrary(
      strategies: [
        for (final strategy in strategies.values)
          StrategyMigrator.migrateToCurrentVersion(
            await StrategyMigrator.migrateLegacyData(strategy),
          ),
      ],
      folders: folders.values.toList(),
    );
  } finally {
    await _closeScratchHive(directory);
  }
}

Future<List<StrategyData>> importIcaFiles(List<File> files) async {
  final directory = await _openScratchHive('library-ica');
  final container = ProviderContainer();
  try {
    final strategies =
        await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
    await MapThemeProfilesProvider.bootstrap();
    final imported = <StrategyData>[];
    for (final file in files) {
      final before = strategies.keys.toSet();
      await StrategyImportExportService(container).loadFromFilePath(file.path);
      final added = strategies.keys.where((key) => !before.contains(key));
      expect(added, hasLength(1), reason: path.basename(file.path));
      imported.add(strategies.get(added.single)!);
    }
    return imported;
  } finally {
    container.dispose();
    await _closeScratchHive(directory);
  }
}

List<Directory> hiveStoresUnder(Directory root) => [
      for (final entity in [root, ...root.listSync(recursive: true)])
        if (entity is Directory &&
            File(path.join(entity.path, '${HiveBoxNames.strategiesBox}.hive'))
                .existsSync())
          entity,
    ];

List<File> icaFilesUnder(Directory root) => [
      for (final entity in root.listSync(recursive: true))
        if (entity is File &&
            path.extension(entity.path).toLowerCase() == '.ica')
          entity,
    ]..sort((a, b) => a.path.compareTo(b.path));
