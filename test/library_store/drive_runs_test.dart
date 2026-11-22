import 'dart:convert';
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
import 'package:icarus/library_rows/strategy_comparison.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/store_check.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/sqlite_storage.dart';
import 'package:path/path.dart' as path;

import 'hive_scratch.dart';

const compareVariable = 'ICARUS_COMPARE_RUNS';
const checkVariable = 'ICARUS_CHECK_RUNS';
const scratchVariable = 'ICARUS_LIBRARY_SCRATCH';
const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');
final _uuid = RegExp(
  '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
);

Directory get _scratchRoot => Directory(
      Platform.environment[scratchVariable] ?? Directory.systemTemp.path,
    );

Future<Directory> _openRun(String run) async {
  final scratch = await _scratchRoot.createTemp('run-');
  final store = Directory(path.join(run, 'store-main'));
  for (final entity in store.listSync(recursive: true)) {
    if (entity is! File) continue;
    final relative = path.relative(entity.path, from: store.path);
    if (path.extension(entity.path) == '.lock') continue;
    final target = File(path.join(scratch.path, relative));
    await target.parent.create(recursive: true);
    await entity.copy(target.path);
  }
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_pathProvider, (_) async => scratch.path);
  await openScratchHive(scratch);
  return scratch;
}

Future<void> _closeRun(Directory scratch) async {
  await Hive.close();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_pathProvider, null);
  await scratch.delete(recursive: true);
}

Future<String> _savedLibrary(String run) async {
  final runId = File(path.join(run, 'run-id')).readAsStringSync().trim();
  final scratch = await _openRun(run);
  try {
    String plain(Object? json) => jsonEncode(json).replaceAll(runId, 'RUN');
    final strategies = [
      for (final strategy
          in Hive.box<StrategyData>(HiveBoxNames.strategiesBox).values)
        {
          ...strategyFingerprint(strategy),
          'createdAt': 0,
          'lastEdited': 0,
        },
    ]..sort((a, b) => plain(a).replaceAll(_uuid, '').compareTo(
          plain(b).replaceAll(_uuid, ''),
        ));
    final folders = [
      for (final folder in Hive.box<Folder>(HiveBoxNames.foldersBox).values)
        {
          'id': folder.id,
          'name': folder.name,
          'parentID': folder.parentID,
          'iconId': folder.iconId,
          'color': folder.color.name,
          'customColor': folder.customColor?.toARGB32(),
        },
    ]..sort((a, b) => plain(a).replaceAll(_uuid, '').compareTo(
          plain(b).replaceAll(_uuid, ''),
        ));
    final ids = <String, String>{};
    return plain({'strategies': strategies, 'folders': folders})
        .replaceAllMapped(
      _uuid,
      (match) => ids.putIfAbsent(match[0]!, () => 'id-${ids.length}'),
    );
  } finally {
    await _closeRun(scratch);
  }
}

Future<String> _checkRun(String run) async {
  final scratch = await _openRun(run);
  try {
    final engine = SqliteEngine(libraryStoreFile(scratch.path).path);
    final store = await openStoreOn(engine);
    final check = await checkFromHive(store);
    await store.close();
    await engine.close();
    return switch (check) {
      StoreNotChecked(:final failure) => 'not checked: $failure',
      StoreChangedDuringCheck() => 'not exact: Hive changed during the check',
      final StoreChecked checked => checked.isExact
          ? 'exact: ${checked.sameStrategies} strategies, '
              '${checked.sameFolders} folders'
          : 'not exact: ${checked.strategyProblems} '
              '${checked.folderProblems} ${checked.foreignNames}',
    };
  } finally {
    await _closeRun(scratch);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    appProviderContainer = ProviderContainer();
    if (!Hive.isAdapterRegistered(20)) registerIcarusAdapters(Hive);
  });
  tearDownAll(() => appProviderContainer.dispose());

  final pairs = Platform.environment[compareVariable];
  test(
    'two driver runs of one script saved the same library',
    skip: pairs == null
        ? '$compareVariable lists run folders in pairs, a:b;c:d'
        : false,
    timeout: const Timeout(Duration(hours: 1)),
    () async {
      final differing = <String>[];
      for (final pair in pairs!.split(';')) {
        final [left, right] = pair.split(':');
        final same = await _savedLibrary(left) == await _savedLibrary(right);
        debugPrint('${path.basename(left)} : ${path.basename(right)} '
            '${same ? 'same' : 'DIFFERENT'}');
        if (!same) differing.add(pair);
      }
      expect(differing, isEmpty);
    },
  );

  final runs = Platform.environment[checkVariable];
  test(
    'the store a driver run left is exact against its Hive library, without copying first',
    skip: runs == null ? '$checkVariable lists run folders, a;b' : false,
    timeout: const Timeout(Duration(hours: 1)),
    () async {
      final inexact = <String>[];
      for (final run in runs!.split(';')) {
        final result = await _checkRun(run);
        debugPrint('${path.basename(run)}: $result');
        if (!result.startsWith('exact')) inexact.add(run);
      }
      expect(inexact, isEmpty);
    },
  );
}
