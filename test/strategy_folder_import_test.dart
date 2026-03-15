import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/favorite_agents_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/map_theme_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/archive_manifest.dart';
import 'package:path/path.dart' as path;

bool _adaptersRegistered = false;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('icarus-folder-import-');
    Hive.init(tempDir.path);
    if (!_adaptersRegistered) {
      registerIcarusAdapters(Hive);
      _adaptersRegistered = true;
    }
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
    container = ProviderContainer();
    await MapThemeProfilesProvider.bootstrap();
  });

  tearDown(() async {
    container.dispose();
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('dropped real folder with nested .ica preserves hierarchy', () async {
    final currentFolder = await _createCurrentFolder(
      container,
      name: 'Current',
    );
    final sourceRoot =
        await Directory(path.join(tempDir.path, 'source', 'Team Strats'))
            .create(recursive: true);
    final childDir =
        await Directory(path.join(sourceRoot.path, 'Retakes')).create();

    await _writeStrategyFile(File(path.join(sourceRoot.path, 'default.ica')));
    await _writeStrategyFile(File(path.join(childDir.path, 'a-site.ica')));

    final result =
        await container.read(strategyProvider.notifier).loadFromFileDrop(
      [XFile(sourceRoot.path)],
    );

    expect(result.strategiesImported, 2);
    expect(result.foldersCreated, 2);
    expect(result.issues, isEmpty);

    final importedRoot = _folderByName('Team Strats');
    final importedChild = _folderByName('Retakes');
    expect(importedRoot.parentID, currentFolder.id);
    expect(importedChild.parentID, importedRoot.id);

    final defaultStrategy = _strategyByName('default');
    final aSiteStrategy = _strategyByName('a-site');
    expect(defaultStrategy.folderID, importedRoot.id);
    expect(aSiteStrategy.folderID, importedChild.id);
  });

  test('dropped real folder with empty subfolders preserves them', () async {
    final sourceRoot =
        await Directory(path.join(tempDir.path, 'source', 'Utility Pack'))
            .create(recursive: true);
    final emptyChild =
        await Directory(path.join(sourceRoot.path, 'No Lineups')).create();
    final emptyGrandchild =
        await Directory(path.join(emptyChild.path, 'Deep Empty')).create();

    final result =
        await container.read(strategyProvider.notifier).loadFromFileDrop(
      [XFile(sourceRoot.path)],
    );

    expect(result.strategiesImported, 0);
    expect(result.foldersCreated, 3);
    expect(result.issues, isEmpty);
    expect(_folderByName('Utility Pack').parentID, isNull);
    expect(
        _folderByName('No Lineups').parentID, _folderByName('Utility Pack').id);
    expect(
        _folderByName('Deep Empty').parentID, _folderByName('No Lineups').id);
    expect(Hive.box<StrategyData>(HiveBoxNames.strategiesBox).values, isEmpty);

    expect(await emptyGrandchild.exists(), isTrue);
  });

  test('dropped zip with single top-level directory matches folder import',
      () async {
    final currentFolder = await _createCurrentFolder(
      container,
      name: 'Current',
    );
    final sourceRoot =
        await Directory(path.join(tempDir.path, 'source', 'Exec Book'))
            .create(recursive: true);
    final nested = await Directory(path.join(sourceRoot.path, 'Mid')).create();

    await _writeStrategyFile(File(path.join(sourceRoot.path, 'hit.ica')));
    await _writeStrategyFile(File(path.join(nested.path, 'split.ica')));

    final zipFile = await _zipDirectory(
      sourceDirectory: sourceRoot,
      zipPath: path.join(tempDir.path, 'exec-book.zip'),
    );

    final result =
        await container.read(strategyProvider.notifier).loadFromFileDrop(
      [XFile(zipFile.path)],
    );

    expect(result.strategiesImported, 2);
    expect(result.foldersCreated, 2);
    expect(result.issues, isEmpty);

    final importedRoot = _folderByName('Exec Book');
    final nestedFolder = _folderByName('Mid');
    expect(importedRoot.parentID, currentFolder.id);
    expect(nestedFolder.parentID, importedRoot.id);
    expect(_strategyByName('hit').folderID, importedRoot.id);
    expect(_strategyByName('split').folderID, nestedFolder.id);
  });

  test('dropped zip with loose top-level contents creates wrapper folder',
      () async {
    final currentFolder = await _createCurrentFolder(
      container,
      name: 'Current',
    );
    final staging =
        await Directory(path.join(tempDir.path, 'staging', 'loose')).create(
      recursive: true,
    );
    final nested = await Directory(path.join(staging.path, 'Nested')).create();

    final rootFile = File(path.join(staging.path, 'root.ica'));
    final nestedFile = File(path.join(nested.path, 'child.ica'));
    await _writeStrategyFile(rootFile);
    await _writeStrategyFile(nestedFile);

    final zipFile = await _createLooseZip(
      zipPath: path.join(tempDir.path, 'mixed.zip'),
      topLevelFiles: [rootFile],
      topLevelDirectories: [nested],
    );

    final result =
        await container.read(strategyProvider.notifier).loadFromFileDrop(
      [XFile(zipFile.path)],
    );

    expect(result.strategiesImported, 2);
    expect(result.foldersCreated, 2);
    expect(result.issues, isEmpty);

    final wrapperFolder = _folderByName('mixed');
    final nestedFolder = _folderByName('Nested');
    expect(wrapperFolder.parentID, currentFolder.id);
    expect(nestedFolder.parentID, wrapperFolder.id);
    expect(_strategyByName('root').folderID, wrapperFolder.id);
    expect(_strategyByName('child').folderID, nestedFolder.id);
  });

  test('manifest zip apply failure does not fall back to legacy import',
      () async {
    final currentFolder = await _createCurrentFolder(
      container,
      name: 'Current',
    );
    final sourceRoot = await Directory(
      path.join(tempDir.path, 'source', 'Broken Manifest Zip'),
    ).create(recursive: true);
    final deepDirectory =
        await Directory(path.join(sourceRoot.path, 'b', 'c')).create(
      recursive: true,
    );

    await _writeStrategyFile(File(path.join(sourceRoot.path, 'root.ica')));
    await _writeStrategyFile(File(path.join(deepDirectory.path, 'deep.ica')));
    await _writeArchiveManifestFile(
      File(path.join(sourceRoot.path, archiveMetadataFileName)),
      _buildBrokenFolderTreeManifest(),
    );

    final zipFile = await _zipDirectory(
      sourceDirectory: sourceRoot,
      zipPath: path.join(tempDir.path, 'broken-manifest.zip'),
    );

    final result =
        await container.read(strategyProvider.notifier).loadFromFileDrop(
      [XFile(zipFile.path)],
    );

    expect(result.strategiesImported, 0);
    expect(result.foldersCreated, 0);
    expect(result.issues, hasLength(1));
    expect(result.issues.single.code, ImportIssueCode.ioError);
    expect(result.issues.single.path, zipFile.path);
    expect(_folderByName('Manifest Root').parentID, currentFolder.id);
    expect(
      Hive.box<Folder>(HiveBoxNames.foldersBox).values.map((folder) => folder.name),
      containsAll(['Current', 'Manifest Root']),
    );
    expect(Hive.box<Folder>(HiveBoxNames.foldersBox).values, hasLength(2));
    expect(
      Hive.box<Folder>(HiveBoxNames.foldersBox)
          .values
          .where((folder) => folder.name == 'broken-manifest'),
      isEmpty,
    );
    expect(
      Hive.box<Folder>(HiveBoxNames.foldersBox)
          .values
          .where((folder) => folder.name == 'b' || folder.name == 'c'),
      isEmpty,
    );
    expect(Hive.box<StrategyData>(HiveBoxNames.strategiesBox).values, isEmpty);
  });

  test('manifest directory apply failure does not fall back to legacy import',
      () async {
    final currentFolder = await _createCurrentFolder(
      container,
      name: 'Current',
    );
    final sourceRoot = await Directory(
      path.join(tempDir.path, 'source', 'broken-manifest-dir'),
    ).create(recursive: true);
    final deepDirectory =
        await Directory(path.join(sourceRoot.path, 'b', 'c')).create(
      recursive: true,
    );

    await _writeStrategyFile(File(path.join(sourceRoot.path, 'root.ica')));
    await _writeStrategyFile(File(path.join(deepDirectory.path, 'deep.ica')));
    await _writeArchiveManifestFile(
      File(path.join(sourceRoot.path, archiveMetadataFileName)),
      _buildBrokenFolderTreeManifest(),
    );

    final result =
        await container.read(strategyProvider.notifier).loadFromFileDrop(
      [XFile(sourceRoot.path)],
    );

    expect(result.strategiesImported, 0);
    expect(result.foldersCreated, 0);
    expect(result.issues, hasLength(1));
    expect(result.issues.single.code, ImportIssueCode.ioError);
    expect(result.issues.single.path, sourceRoot.path);
    expect(_folderByName('Manifest Root').parentID, currentFolder.id);
    expect(
      Hive.box<Folder>(HiveBoxNames.foldersBox).values.map((folder) => folder.name),
      containsAll(['Current', 'Manifest Root']),
    );
    expect(Hive.box<Folder>(HiveBoxNames.foldersBox).values, hasLength(2));
    expect(
      Hive.box<Folder>(HiveBoxNames.foldersBox)
          .values
          .where((folder) => folder.name == 'broken-manifest-dir'),
      isEmpty,
    );
    expect(
      Hive.box<Folder>(HiveBoxNames.foldersBox)
          .values
          .where((folder) => folder.name == 'b' || folder.name == 'c'),
      isEmpty,
    );
    expect(Hive.box<StrategyData>(HiveBoxNames.strategiesBox).values, isEmpty);
  });

  test('folder export manifest preserves folder visuals on round-trip',
      () async {
    final rootFolder = await _createFolder(
      container,
      name: 'Utility / Pack',
      parentID: null,
      icon: Icons.flag,
      color: FolderColor.custom,
      customColor: const Color(0xFF22C55E),
    );
    final childFolder = await _createFolder(
      container,
      name: 'Retakes',
      parentID: rootFolder.id,
      icon: Icons.lightbulb,
      color: FolderColor.blue,
    );

    await _storeStrategy(name: 'default', folderID: rootFolder.id);
    await _storeStrategy(name: 'a-site', folderID: childFolder.id);

    final exportDirectory = await container
        .read(strategyProvider.notifier)
        .buildFolderExportDirectoryForTest(rootFolder.id);

    try {
      final exportedRoot = exportDirectory.listSync().whereType<Directory>().single;
      final manifestFile =
          File(path.join(exportedRoot.path, archiveMetadataFileName));
      expect(await manifestFile.exists(), isTrue);

      final decoded = Map<String, dynamic>.from(
        jsonDecode(await manifestFile.readAsString()) as Map,
      );
      expect(decoded['archiveType'], ArchiveType.folderTree.jsonValue);
      expect((decoded['folders'] as List).length, 2);
      expect((decoded['strategies'] as List).length, 2);

      final zipFile = await _zipDirectory(
        sourceDirectory: exportedRoot,
        zipPath: path.join(tempDir.path, 'folder-manifest.zip'),
      );

      await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).clear();
      await Hive.box<Folder>(HiveBoxNames.foldersBox).clear();

      final result =
          await container.read(strategyProvider.notifier).loadFromFileDrop(
        [XFile(zipFile.path)],
      );

      expect(result.strategiesImported, 2);
      expect(result.foldersCreated, 2);
      expect(result.issues, isEmpty);

      final importedRoot = _folderByName('Utility / Pack');
      final importedChild = _folderByName('Retakes');
      expect(importedRoot.icon.codePoint, Icons.flag.codePoint);
      expect(importedRoot.color, FolderColor.custom);
      expect(importedRoot.customColor, const Color(0xFF22C55E));
      expect(importedChild.icon.codePoint, Icons.lightbulb.codePoint);
      expect(importedChild.color, FolderColor.blue);
      expect(importedChild.parentID, importedRoot.id);
      expect(_strategyByName('default').folderID, importedRoot.id);
      expect(_strategyByName('a-site').folderID, importedChild.id);
    } finally {
      if (await exportDirectory.exists()) {
        await exportDirectory.delete(recursive: true);
      }
    }
  });

  test('library backup restores global state and theme profile links', () async {
    final themeProvider = container.read(mapThemeProfilesProvider.notifier);
    final palette = MapThemePalette(
      baseColorValue: 0xFF0F172A,
      detailColorValue: 0xFF38BDF8,
      highlightColorValue: 0xFFF97316,
    );
    expect(
      await themeProvider.createProfile(name: 'Tournament', palette: palette),
      isTrue,
    );
    final customProfile = Hive.box<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox)
        .values
        .firstWhere((profile) => profile.name == 'Tournament');
    await themeProvider.setDefaultProfileForNewStrategies(customProfile.id);
    await container
        .read(favoriteAgentsProvider.notifier)
        .toggleFavorite(AgentType.jett);

    final folder = await _createFolder(
      container,
      name: 'Plays',
      parentID: null,
    );
    await _storeStrategy(
      name: 'Root Backup',
      folderID: null,
      themeProfileId: customProfile.id,
    );
    await _storeStrategy(
      name: 'Folder Backup',
      folderID: folder.id,
      themeProfileId: customProfile.id,
    );

    final exportDirectory = await container
        .read(strategyProvider.notifier)
        .buildLibraryExportDirectoryForTest();

    try {
      final rootDirectory = Directory(
        path.join(exportDirectory.path, libraryBackupRootDirectoryName),
      );
      final manifestFile =
          File(path.join(rootDirectory.path, archiveMetadataFileName));
      expect(await manifestFile.exists(), isTrue);

      final zipFile = await _zipDirectory(
        sourceDirectory: rootDirectory,
        zipPath: path.join(tempDir.path, 'library-backup.zip'),
      );

      await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).clear();
      await Hive.box<Folder>(HiveBoxNames.foldersBox).clear();
      await Hive.box<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox).clear();
      await Hive.box<AppPreferences>(HiveBoxNames.appPreferencesBox).clear();
      await Hive.box<bool>(HiveBoxNames.favoriteAgentsBox).clear();
      await MapThemeProfilesProvider.bootstrap();

      final result =
          await container.read(strategyProvider.notifier).loadFromFileDrop(
        [XFile(zipFile.path)],
      );

      expect(result.strategiesImported, 2);
      expect(result.foldersCreated, 1);
      expect(result.themeProfilesImported, 1);
      expect(result.globalStateRestored, isTrue);
      expect(result.issues, isEmpty);

      final restoredProfile =
          Hive.box<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox)
              .values
              .firstWhere((profile) => profile.name == 'Tournament');
      final restoredRoot = _strategyByName('Root Backup');
      final restoredFolderStrategy = _strategyByName('Folder Backup');
      expect(restoredRoot.themeProfileId, restoredProfile.id);
      expect(restoredFolderStrategy.themeProfileId, restoredProfile.id);
      expect(
        Hive.box<AppPreferences>(HiveBoxNames.appPreferencesBox)
            .get(MapThemeProfilesProvider.appPreferencesSingletonKey)
            ?.defaultThemeProfileIdForNewStrategies,
        restoredProfile.id,
      );
      expect(
        Hive.box<bool>(HiveBoxNames.favoriteAgentsBox).containsKey('jett'),
        isTrue,
      );
    } finally {
      if (await exportDirectory.exists()) {
        await exportDirectory.delete(recursive: true);
      }
    }
  });

  test('batch import skips newer-version strategies and keeps valid siblings',
      () async {
    final sourceRoot =
        await Directory(path.join(tempDir.path, 'source', 'Version Mix'))
            .create(recursive: true);
    await _writeStrategyFile(File(path.join(sourceRoot.path, 'valid.ica')));
    await _writeStrategyFile(
      File(path.join(sourceRoot.path, 'future.ica')),
      versionNumber: Settings.versionNumber + 1,
    );

    final result =
        await container.read(strategyProvider.notifier).loadFromFileDrop(
      [XFile(sourceRoot.path)],
    );

    expect(result.strategiesImported, 1);
    expect(result.foldersCreated, 1);
    expect(result.issues, hasLength(1));
    expect(result.issues.single.code, ImportIssueCode.newerVersion);
    expect(_strategyByName('valid').folderID, _folderByName('Version Mix').id);
    expect(
      Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
          .values
          .where((strategy) => strategy.name == 'future'),
      isEmpty,
    );
  });

  test('standalone .ica drop imports into the current folder', () async {
    final parentFolder = await _createFolder(
      container,
      name: 'Parent',
      parentID: null,
    );
    final currentFolder = await _createFolder(
      container,
      name: 'Current',
      parentID: parentFolder.id,
      setCurrent: true,
    );
    final file = File(path.join(tempDir.path, 'solo.ica'));
    await _writeStrategyFile(file);

    final result =
        await container.read(strategyProvider.notifier).loadFromFileDrop(
      [XFile(file.path)],
    );

    expect(result.strategiesImported, 1);
    expect(result.foldersCreated, 0);
    expect(result.issues, isEmpty);
    expect(_strategyByName('solo').folderID, currentFolder.id);
  });

  test(
      'nested unsupported files are reported and valid strategies still import',
      () async {
    final sourceRoot =
        await Directory(path.join(tempDir.path, 'source', 'Mixed Folder'))
            .create(recursive: true);
    final nested =
        await Directory(path.join(sourceRoot.path, 'Nested')).create();

    await _writeStrategyFile(File(path.join(sourceRoot.path, 'valid.ica')));

    final nestedText = File(path.join(nested.path, 'notes.txt'));
    await nestedText.create(recursive: true);
    await nestedText.writeAsString('notes');

    final nestedZipSource =
        await Directory(path.join(tempDir.path, 'zip-source', 'bundle'))
            .create(recursive: true);
    await _writeStrategyFile(
        File(path.join(nestedZipSource.path, 'inside.ica')));
    final nestedZip = await _zipDirectory(
      sourceDirectory: nestedZipSource,
      zipPath: path.join(nested.path, 'nested.zip'),
    );

    final result =
        await container.read(strategyProvider.notifier).loadFromFileDrop(
      [XFile(sourceRoot.path)],
    );

    expect(result.strategiesImported, 1);
    expect(result.foldersCreated, 2);
    expect(
      result.issues
          .where((issue) => issue.code == ImportIssueCode.unsupportedFile),
      hasLength(2),
    );
    expect(
      result.issues.map((issue) => issue.path),
      containsAll([nestedText.path, nestedZip.path]),
    );
    expect(_strategyByName('valid').folderID, _folderByName('Mixed Folder').id);
  });

  test('empty folder plus unsupported nested file reports one skipped file',
      () async {
    final sourceRoot =
        await Directory(path.join(tempDir.path, 'source', 'Folder Only'))
            .create(recursive: true);
    final emptyNested =
        await Directory(path.join(sourceRoot.path, 'Empty Nested')).create();
    final nestedText = File(path.join(sourceRoot.path, 'notes.txt'));
    await nestedText.create(recursive: true);
    await nestedText.writeAsString('notes');

    final result =
        await container.read(strategyProvider.notifier).loadFromFileDrop(
      [XFile(sourceRoot.path)],
    );

    expect(result.strategiesImported, 0);
    expect(result.foldersCreated, 2);
    expect(result.issues, hasLength(1));
    expect(result.issues.single.code, ImportIssueCode.unsupportedFile);
    expect(result.issues.single.path, nestedText.path);
    expect(_folderByName('Folder Only').parentID, isNull);
    expect(_folderByName('Empty Nested').parentID,
        _folderByName('Folder Only').id);
    expect(await emptyNested.exists(), isTrue);
  });

  test('unsupported dropped files are reported and ignored', () async {
    final file = File(path.join(tempDir.path, 'notes.txt'));
    await file.create(recursive: true);
    await file.writeAsString('not a strategy');

    final result =
        await container.read(strategyProvider.notifier).loadFromFileDrop(
      [XFile(file.path)],
    );

    expect(result.strategiesImported, 0);
    expect(result.foldersCreated, 0);
    expect(result.issues, hasLength(1));
    expect(result.issues.single.code, ImportIssueCode.unsupportedFile);
    expect(Hive.box<StrategyData>(HiveBoxNames.strategiesBox).values, isEmpty);
    expect(Hive.box<Folder>(HiveBoxNames.foldersBox).values, isEmpty);
  });
}

Future<void> _writeStrategyFile(
  File file, {
  int? versionNumber,
}) async {
  await file.parent.create(recursive: true);
  await file.writeAsString(
    jsonEncode({
      'versionNumber': versionNumber ?? Settings.versionNumber,
      'mapData': 'ascent',
      'drawingData': const [],
      'agentData': const [],
      'abilityData': const [],
      'textData': const [],
      'imageData': const [],
      'utilityData': const [],
      'pages': const [],
    }),
  );
}

Future<File> _zipDirectory({
  required Directory sourceDirectory,
  required String zipPath,
}) async {
  final encoder = ZipFileEncoder()..create(zipPath);
  await encoder.addDirectory(sourceDirectory);
  await encoder.close();
  return File(zipPath);
}

Future<File> _createLooseZip({
  required String zipPath,
  required List<File> topLevelFiles,
  required List<Directory> topLevelDirectories,
}) async {
  final encoder = ZipFileEncoder()..create(zipPath);

  for (final file in topLevelFiles) {
    await encoder.addFile(file);
  }

  for (final directory in topLevelDirectories) {
    await encoder.addDirectory(directory);
  }

  await encoder.close();
  return File(zipPath);
}

Future<void> _writeArchiveManifestFile(
  File file,
  ArchiveManifest manifest,
) async {
  await file.parent.create(recursive: true);
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
  );
}

ArchiveManifest _buildBrokenFolderTreeManifest() {
  final defaultIcon = ArchiveIconDescriptor.fromIconData(Icons.folder);

  return ArchiveManifest(
    schemaVersion: archiveManifestSchemaVersion,
    archiveType: ArchiveType.folderTree,
    exportedAt: DateTime.utc(2026, 1, 1),
    appVersionNumber: Settings.versionNumber,
    folders: [
      ArchiveFolderEntry(
        manifestId: 'root',
        name: 'Manifest Root',
        parentManifestId: null,
        archivePath: '',
        icon: defaultIcon,
        color: FolderColor.red,
        customColorValue: null,
      ),
      ArchiveFolderEntry(
        manifestId: 'broken-child',
        name: 'Broken Child',
        parentManifestId: 'deep-parent',
        archivePath: 'b',
        icon: defaultIcon,
        color: FolderColor.red,
        customColorValue: null,
      ),
      ArchiveFolderEntry(
        manifestId: 'deep-parent',
        name: 'Deep Parent',
        parentManifestId: 'root',
        archivePath: 'b/c',
        icon: defaultIcon,
        color: FolderColor.red,
        customColorValue: null,
      ),
    ],
    strategies: const [
      ArchiveStrategyEntry(
        name: 'root',
        archivePath: 'root.ica',
        folderManifestId: 'root',
      ),
      ArchiveStrategyEntry(
        name: 'deep',
        archivePath: 'b/c/deep.ica',
        folderManifestId: 'deep-parent',
      ),
    ],
    globals: null,
  );
}

Future<Folder> _createCurrentFolder(
  ProviderContainer container, {
  required String name,
}) async {
  return _createFolder(
    container,
    name: name,
    parentID: null,
    setCurrent: true,
  );
}

Future<Folder> _createFolder(
  ProviderContainer container, {
  required String name,
  required String? parentID,
  IconData icon = Icons.folder,
  FolderColor color = FolderColor.red,
  Color? customColor,
  bool setCurrent = false,
}) async {
  final notifier = container.read(folderProvider.notifier);
  final folder = await notifier.createFolder(
    name: name,
    icon: icon,
    color: color,
    customColor: customColor,
    parentID: parentID,
  );

  if (setCurrent) {
    notifier.updateID(folder.id);
  }

  return folder;
}

Future<void> _storeStrategy({
  required String name,
  required String? folderID,
  String? themeProfileId,
}) async {
  final strategy = StrategyData(
    id: 'strategy-$name-${DateTime.now().microsecondsSinceEpoch}',
    name: name,
    mapData: MapValue.ascent,
    versionNumber: Settings.versionNumber,
    lastEdited: DateTime.utc(2026, 1, 1),
    folderID: folderID,
    pages: const [],
    themeProfileId: themeProfileId,
  );
  await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
      .put(strategy.id, strategy);
}

Folder _folderByName(String name) {
  return Hive.box<Folder>(HiveBoxNames.foldersBox)
      .values
      .firstWhere((folder) => folder.name == name);
}

StrategyData _strategyByName(String name) {
  return Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
      .values
      .firstWhere((strategy) => strategy.name == name);
}
