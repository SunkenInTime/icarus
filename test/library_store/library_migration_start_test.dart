import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/library_store/library_migration.dart';
import 'package:icarus/library_store/library_migration_start.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/sqlite_storage.dart';

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
    LocalLibrary.source = const LibraryInHive();
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

  group('serving the library from the store', () {
    late ProviderContainer container;
    late int broughtUpToDate;
    late int servedAgain;

    setUp(() {
      container = ProviderContainer();
      broughtUpToDate = 0;
      servedAgain = 0;
    });
    tearDown(() async {
      await container.read(libraryStoreProvider.notifier).close();
      container.dispose();
    });

    Future<void> open() => openLibraryOnStore(
          container,
          _launch(LibraryStoreLaunch.storeFlag),
          hiveDirectory: directory.path,
          allowsLocalLibrary: true,
          build: '',
          bringUpToDate: () async => broughtUpToDate++,
          servedAgain: () => servedAgain++,
        );

    List<String> served() =>
        [for (final s in const LocalLibrary().storedStrategies) s.id];

    test('after a finished move the library is served from the store',
        () async {
      await open();

      expect(container.read(libraryOnStoreProvider),
          isA<LibraryServedFromStore>());
      expect(LocalLibrary.source, isA<LibraryInStore>());
      expect(served(), ['a', 'b']);
    });

    test(
        'once the move has finished, a start leaves Hive\'s library boxes '
        'closed and still serves the library', () async {
      await open();
      await container.read(libraryStoreProvider.notifier).close();
      await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).close();
      await Hive.box<Folder>(HiveBoxNames.foldersBox).close();

      await open();

      expect(container.read(libraryMigrationProvider)!.migration,
          isA<MigrationWasFinished>());
      expect(served(), ['a', 'b']);
      expect(Hive.isBoxOpen(HiveBoxNames.strategiesBox), isFalse);
      expect(Hive.isBoxOpen(HiveBoxNames.foldersBox), isFalse);
    });

    test('a move still to run opens Hive\'s library boxes to copy from',
        () async {
      await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).close();
      await Hive.box<Folder>(HiveBoxNames.foldersBox).close();

      await open();

      expect(container.read(libraryMigrationProvider)!.migration,
          isA<MigrationFinishedNow>());
      expect(served(), ['a', 'b']);
      expect(Hive.isBoxOpen(HiveBoxNames.strategiesBox), isTrue);
    });

    test('a later start serves what the store holds, whatever Hive holds since',
        () async {
      await open();
      await container.read(libraryStoreProvider.notifier).close();
      final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
      await box.delete('a');
      await box.put(
        'z',
        generatedStrategy(Optionals.unset).copyWith(id: 'z', name: 'Z'),
      );
      await box.put(
        'b',
        generatedStrategy(Optionals.unset).copyWith(id: 'b', name: 'B in Hive'),
      );

      await open();

      expect(container.read(libraryMigrationProvider)!.migration,
          isA<MigrationWasFinished>());
      expect(served(), ['a', 'b']);
      expect(const LocalLibrary().storedStrategy('b')!.name, 'B');
    });

    test(
        'closing the left-behind dialog is kept in the store, with what was '
        'left behind, across a reopen', () async {
      await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).put(
        'newer',
        generatedStrategy(Optionals.unset).copyWith(
          id: 'newer',
          name: 'Newer',
          versionNumber: Settings.versionNumber + 1,
        ),
      );
      await open();
      final first =
          switch (container.read(libraryMigrationProvider)!.migration) {
        MigrationFinishedNow(:final record) => record,
        final other => fail('$other'),
      };
      expect(first.leftBehindClosed, isFalse);

      await recordLeftBehindClosed(container, first);
      await container.read(libraryStoreProvider.notifier).close();
      await open();

      final again =
          switch (container.read(libraryMigrationProvider)!.migration) {
        MigrationWasFinished(:final record) => record,
        final other => fail('$other'),
      };
      expect(again.leftBehindClosed, isTrue);
      List<(String, String, String)> named(List<LeftBehind> entries) => [
            for (final entry in entries)
              (entry.publicId, entry.name, entry.reason),
          ];
      expect(named(again.strategies), named(first.strategies));
      expect(named(again.folders), named(first.folders));
      expect(named(again.strategies).single.$1, 'newer');
    });

    test(
        'a store that opens ready with a record of the copy it cannot read '
        'serves no library, and no write reaches the store or Hive', () async {
      final file = libraryStoreFile(directory.path)
        ..parent.createSync(recursive: true);
      final engine = SqliteEngine(file.path);
      final lease = switch (await engine.lease()) {
        Leased(:final lease) => lease,
        final other => fail('$other'),
      };
      expect(
        await lease.commit([
          const Put('library', 'migration', '{"state": "half done"}'),
        ]),
        isA<CommitApplied>(),
      );
      await lease.release();
      await engine.close();

      await open();

      expect(container.read(libraryStoreProvider), isA<LibraryStoreReady>());
      final notServed =
          container.read(libraryOnStoreProvider)! as LibraryNotServed;
      expect(notServed.oldLibraryFolder, directory.path);
      expect(LocalLibrary.source, isA<LibraryNotOpened>());
      expect(served(), isEmpty);
      final written = await const LocalLibrary().addStrategy(
        generatedStrategy(Optionals.unset).copyWith(id: 'new', name: 'New'),
      );
      expect(written, isA<LibraryWriteFailed>());
      final store =
          (container.read(libraryStoreProvider) as LibraryStoreReady).store;
      expect((store.library as LibraryOpen).list.strategies, isEmpty);
      expect(
        Hive.box<StrategyData>(HiveBoxNames.strategiesBox).keys,
        ['a', 'b'],
      );
    });

    test(
        'trying again after the store could not be opened serves the library '
        'once it opens, and brings it up to date', () async {
      final blocking = File(libraryStoreFile(directory.path).parent.path)
        ..writeAsStringSync('in the way');

      await open();

      expect(container.read(libraryOnStoreProvider), isA<LibraryNotServed>());
      expect(LocalLibrary.source, isA<LibraryNotOpened>());
      blocking.deleteSync();

      await (container.read(libraryOnStoreProvider)! as LibraryNotServed)
          .tryAgain();

      expect(container.read(libraryOnStoreProvider),
          isA<LibraryServedFromStore>());
      expect(served(), ['a', 'b']);
      expect(broughtUpToDate, 1);
      expect(servedAgain, 1);
    });
  });
}
