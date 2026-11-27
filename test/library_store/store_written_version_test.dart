import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/library_store/library_migration_start.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/sqlite_storage.dart';

import '../library_rows/generated_strategies.dart';
import 'hive_scratch.dart';

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
    directory = await Directory.systemTemp.createTemp('icarus-written-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, (_) async => directory.path);
    await openScratchHive(directory, strategies: [
      generatedStrategy(Optionals.set).copyWith(id: 'a', name: 'Alpha'),
    ]);
  });
  tearDown(() async {
    LocalLibrary.source = const LibraryInHive();
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null);
    await directory.delete(recursive: true);
  });

  Future<({LibraryOnStore onStore, int saves})> start() async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await openLibraryOnStore(
      container,
      LibraryStoreLaunch.parse(
        const [LibraryStoreLaunch.storeFlag],
        mayShadow: true,
      ),
      hiveDirectory: directory.path,
      allowsLocalLibrary: true,
      build: '',
      bringUpToDate: () async {},
      servedAgain: () {},
    );
    final onStore = container.read(libraryOnStoreProvider)!;
    var saves = 0;
    if (onStore is LibraryServedFromStore) {
      final saving =
          const LocalLibrary().strategyRecords.changes().listen((_) => saves++);
      await StrategyMigrator.migrateAllStrategies();
      await pumpEventQueue();
      await saving.cancel();
    }
    await container.read(libraryStoreProvider.notifier).close();
    return (onStore: onStore, saves: saves);
  }

  Future<String?> writtenInStore() async {
    final engine = SqliteEngine(libraryStoreFile(directory.path).path);
    final lease = switch (await engine.lease()) {
      Leased(:final lease) => lease,
      final other => fail('$other'),
    };
    final value = switch (await lease.read(strategyArea('a'), 'written')) {
      KeyHeld(:final value) => value,
      KeyMissing() => null,
      KeyNotRead(:final failure) => fail('$failure'),
    };
    await lease.release();
    await engine.close();
    return value;
  }

  Future<void> recordInStore(String? written) async {
    final engine = SqliteEngine(libraryStoreFile(directory.path).path);
    final lease = switch (await engine.lease()) {
      Leased(:final lease) => lease,
      final other => fail('$other'),
    };
    expect(
      await lease.commit([
        switch (written) {
          final value? => Put(strategyArea('a'), 'written', value),
          null => Delete(strategyArea('a'), 'written'),
        },
      ]),
      isA<CommitApplied>(),
    );
    await lease.release();
    await engine.close();
  }

  test('the copy records the version it brought each strategy up to', () async {
    expect((await start()).onStore, isA<LibraryServedFromStore>());

    expect(await writtenInStore(), '${Settings.versionNumber}');
  });

  test(
      'a strategy written by the version before is brought up to date and '
      'saved once; the next start saves nothing', () async {
    await start();
    await recordInStore('${Settings.versionNumber - 1}');

    final upgraded = await start();
    expect(upgraded.onStore, isA<LibraryServedFromStore>());
    expect(upgraded.saves, 1);
    expect(await writtenInStore(), '${Settings.versionNumber}');

    final again = await start();
    expect(again.saves, 0);
    expect(await writtenInStore(), '${Settings.versionNumber}');
  });

  test(
      'a strategy written by a newer version is refused: the library is not '
      'served and nothing is written', () async {
    await start();
    await recordInStore('${Settings.versionNumber + 1}');
    final hive = File('${directory.path}/${HiveBoxNames.strategiesBox}.hive')
        .readAsBytesSync();

    final refused = await start();

    expect(
      refused.onStore,
      isA<LibraryNotServed>().having(
        (notServed) => notServed.why,
        'why',
        contains('newer version of Icarus (${Settings.versionNumber + 1})'),
      ),
    );
    expect(refused.saves, 0);
    expect(await writtenInStore(), '${Settings.versionNumber + 1}');
    expect(
      File('${directory.path}/${HiveBoxNames.strategiesBox}.hive')
          .readAsBytesSync(),
      hive,
    );
  });

  test(
      'a strategy with no record of its version names itself and says the '
      'store was written before the record was kept', () async {
    await start();
    await recordInStore(null);

    final refused = await start();

    expect(
      refused.onStore,
      isA<LibraryNotServed>().having(
        (notServed) => notServed.why,
        'why',
        allOf(
          contains('"Alpha" (a)'),
          endsWith('before that record was kept'),
        ),
      ),
    );
    expect(await writtenInStore(), isNull);
  });
}
