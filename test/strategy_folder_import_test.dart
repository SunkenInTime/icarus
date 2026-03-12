import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/hive/hive_registrar.g.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
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
      Hive.registerAdapters();
      _adaptersRegistered = true;
    }
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    container = ProviderContainer();
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
  bool setCurrent = false,
}) async {
  final notifier = container.read(folderProvider.notifier);
  final folder = await notifier.createFolder(
    name: name,
    icon: Icons.folder,
    color: FolderColor.red,
    parentID: parentID,
  );

  if (setCurrent) {
    notifier.updateID(folder.id);
  }

  return folder;
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
