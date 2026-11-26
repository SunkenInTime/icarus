import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/services/archive_manifest.dart';
import 'package:icarus/services/image_file_name.dart';
import 'package:icarus/library_store/library_store_start.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/strategy/export_strategy_reads.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:path/path.dart' as path;

import 'library_rows/generated_strategies.dart';

final class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

final _expectedFile = File(
  path.join('test', 'fixtures', 'library_export', 'expected.json'),
);

const _writeExpected = 'ICARUS_WRITE_EXPORT_EXPECTED';

List<Folder> _folders() => [
      Folder(
        name: 'Retakes',
        id: 'folder-1',
        dateCreated: DateTime.utc(2026, 1, 2),
      ),
      Folder(
        name: 'B site',
        id: 'folder-2',
        dateCreated: DateTime.utc(2026, 1, 3),
        parentID: 'folder-1',
      ),
      Folder(
        name: 'Empty',
        id: 'folder-3',
        dateCreated: DateTime.utc(2026, 1, 4),
      ),
    ];

List<StrategyData> _strategies() => [
      generatedStrategy(Optionals.set),
      generatedStrategy(Optionals.unset),
      generatedStrategy(Optionals.set)
          .copyWith(id: 'strategy-deep', name: 'Deep', folderID: 'folder-2'),
    ];

Object? _described(File file) {
  final name = path.basename(file.path);
  if (name == archiveMetadataFileName) {
    return _manifest(jsonDecode(file.readAsStringSync()));
  }
  if (path.extension(name) != '.ica') return 'file';
  final archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
  return {
    for (final entry
        in archive.files.toList()..sort((a, b) => a.name.compareTo(b.name)))
      entry.name: path.extension(entry.name) == '.json'
          ? _currentVersion(jsonDecode(utf8.decode(entry.content as List<int>)))
          : 'file',
  };
}

Object? _currentVersion(Object? json) => switch (json) {
      {'versionNumber': final version}
          when version == '${Settings.versionNumber}' =>
        {...json as Map<String, Object?>, 'versionNumber': 'this build'},
      _ => json,
    };

Object? _manifest(Object? json) {
  final ids = <String, String>{};
  String label(Object? id) =>
      ids.putIfAbsent(id as String, () => 'folder ${ids.length + 1}');
  final manifest = {...json as Map<String, Object?>}..remove('exportedAt');
  if (manifest['appVersionNumber'] == Settings.versionNumber) {
    manifest['appVersionNumber'] = 'this build';
  }
  manifest['folders'] = [
    for (final folder in manifest['folders'] as List)
      {
        ...folder as Map<String, Object?>,
        'manifestId': label(folder['manifestId']),
        if (folder['parentManifestId'] case final parent?)
          'parentManifestId': label(parent),
      },
  ];
  manifest['strategies'] = [
    for (final strategy in manifest['strategies'] as List)
      {
        ...strategy as Map<String, Object?>,
        if (strategy['folderManifestId'] case final folder?)
          'folderManifestId': label(folder),
      },
  ];
  return manifest;
}

Map<String, Object?> _tree(Directory root) => {
      for (final file
          in root.listSync(recursive: true).whereType<File>().toList()
            ..sort((a, b) => a.path.compareTo(b.path)))
        path.posix
                .joinAll(path.split(path.relative(file.path, from: root.path))):
            _described(file),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late ProviderContainer container;

  setUpAll(() => appProviderContainer = ProviderContainer());
  tearDownAll(() => appProviderContainer.dispose());

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('icarus-export-contents-');
    final support = await Directory(path.join(temp.path, 'support')).create();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, (call) async => support.path);
    Hive.init(path.join(temp.path, 'hive'));
    if (!Hive.isAdapterRegistered(20)) registerIcarusAdapters(Hive);
    final strategies =
        await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    final folders = await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
    for (final folder in _folders()) {
      await folders.put(folder.id, folder);
    }
    for (final strategy in _strategies()) {
      await strategies.put(strategy.id, strategy);
    }
    final pictures = await Directory(path.join(
      strategyFolderPath(support.path, 'strategy-set'),
      'images',
    )).create(recursive: true);
    File(path.join(pictures.path, 'strategy-set-picture.png'))
        .writeAsBytesSync([1, 2, 3]);
    File(path.join(pictures.path, 'left-behind.jpg')).writeAsBytesSync([4, 5]);
    container = ProviderContainer(
      overrides: [authProvider.overrideWith(_SignedOut.new)],
    );
  });

  tearDown(() async {
    container.dispose();
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null);
    await temp.delete(recursive: true);
  });

  Future<Map<String, Object?>> exported([ProviderContainer? reading]) async {
    final service = StrategyImportExportService(reading ?? container);
    final library = await service.buildLibraryExportDirectoryForTest();
    final folder = await service.buildFolderExportDirectoryForTest('folder-1');
    final single = File(path.join(temp.path, 'single.ica'));
    await service.zipStrategy(id: 'strategy-set', outputFilePath: single.path);
    try {
      return {
        'backup': _tree(library),
        'folder export': _tree(folder),
        'single .ica': _described(single),
      };
    } finally {
      await library.delete(recursive: true);
      await folder.delete(recursive: true);
    }
  }

  test(
      'a backup, a folder export and a single .ica hold the same files, '
      'strategy JSON and manifest as main writes', () async {
    final written = await exported();
    if (Platform.environment[_writeExpected] == '1') {
      await _expectedFile.parent.create(recursive: true);
      await _expectedFile.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(written)}\n',
      );
    }
    expect(
      jsonDecode(jsonEncode(written)),
      jsonDecode(await _expectedFile.readAsString()),
    );
  });

  test('with the store switched off, exports read strategies from Hive', () {
    final start = LibraryStoreStart.of(
      const StoreSwitchOff(),
      clock: () => Duration.zero,
    );
    final off = ProviderContainer(overrides: start.overrides);
    addTearDown(off.dispose);

    expect(off.read(exportStrategyReadsProvider), isA<HiveExportReads>());
  });

  test(
      'a backup, a folder export and a single .ica read each strategy they '
      'write through the export reader, once', () async {
    final reads = _CountedReads();
    final reading = ProviderContainer(overrides: [
      authProvider.overrideWith(_SignedOut.new),
      exportStrategyReadsProvider.overrideWithValue(reads),
    ]);
    addTearDown(reading.dispose);

    final written = await exported(reading);

    expect(reads.ids..sort(), [
      'strategy-deep',
      'strategy-deep',
      'strategy-set',
      'strategy-set',
      'strategy-set',
      'strategy-unset',
    ]);
    expect(
      jsonDecode(jsonEncode(written)),
      jsonDecode(await _expectedFile.readAsString()),
    );
  });
}

final class _CountedReads implements ExportStrategyReads {
  final ids = <String>[];

  @override
  Future<StrategyData?> read(String strategyId) {
    ids.add(strategyId);
    return const HiveExportReads().read(strategyId);
  }
}
