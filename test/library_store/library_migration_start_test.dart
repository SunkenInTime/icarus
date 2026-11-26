import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/library_store/library_migration.dart';
import 'package:icarus/library_store/library_migration_start.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

import '../library_rows/generated_strategies.dart';
import 'hive_scratch.dart';

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

LibraryStoreLaunch _launch(String flag) =>
    LibraryStoreLaunch.parse([flag], mayShadow: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('icarus-move-start-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, (_) async => directory.path);
    await openScratchHive(directory, strategies: [
      generatedStrategy(Optionals.unset).copyWith(id: 'a', name: 'A'),
      generatedStrategy(Optionals.unset).copyWith(id: 'b', name: 'B'),
    ]);
  });
  tearDown(() async {
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null);
    await directory.delete(recursive: true);
  });

  Future<MigrationAtStart?> start(String flag) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final opening = await moveLibraryIntoStore(
      container,
      _launch(flag),
      hiveDirectory: directory.path,
      allowsLocalLibrary: true,
      build: '',
    );
    if (opening == null) {
      expect(container.read(libraryStoreProvider), isA<LibraryStoreOff>());
    }
    final atStart = container.read(libraryMigrationProvider);
    await container.read(libraryStoreProvider.notifier).close();
    return atStart;
  }

  test(
      'in every mode but store, and with the store off, the start opens no '
      'store and moves nothing', () async {
    for (final flag in [
      LibraryStoreLaunch.offFlag,
      LibraryStoreLaunch.shadowFlag,
      LibraryStoreLaunch.mirrorFlag,
      LibraryStoreLaunch.readFlag,
      LibraryStoreLaunch.opsFlag,
    ]) {
      expect(await start(flag), isNull, reason: flag);
    }
    expect(libraryStoreFile(directory.path).existsSync(), isFalse);
  });

  test(
      'in store mode the start moves the library into the store file beside '
      'the Hive files, and the next start finds the move finished', () async {
    final first = await start(LibraryStoreLaunch.storeFlag);

    expect(first!.migration, isA<MigrationFinishedNow>());
    expect(first.oldLibraryFolder, directory.path);
    expect(libraryStoreFile(directory.path).existsSync(), isTrue);

    final second = await start(LibraryStoreLaunch.storeFlag);
    expect(second!.migration, isA<MigrationWasFinished>());
  });

  test(
      'of two Hive records with one id, the one stored under that id is '
      'copied, even when the other comes first in Hive, and the other is left '
      'behind, named', () async {
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    await box.put(
      '0-alias',
      generatedStrategy(Optionals.unset).copyWith(id: 'b', name: 'B again'),
    );
    expect(box.keys.first, '0-alias');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    await moveLibraryIntoStore(
      container,
      _launch(LibraryStoreLaunch.storeFlag),
      hiveDirectory: directory.path,
      allowsLocalLibrary: true,
      build: '',
    );
    final store = switch (container.read(libraryStoreProvider)) {
      LibraryStoreReady(:final store) => store,
      final other => fail('$other'),
    };
    final record = (container.read(libraryMigrationProvider)!.migration
            as MigrationFinishedNow)
        .record;
    final names = {
      for (final summary in (store.library as LibraryOpen).list.strategies)
        summary.publicId: summary.name,
    };
    await container.read(libraryStoreProvider.notifier).close();

    expect(
      [
        for (final left in record.strategies)
          (left.publicId, left.name, left.reason),
      ],
      [('b', 'B again', sameIdTwice)],
    );
    expect(names, {'a': 'A', 'b': 'B'});
  });
}
