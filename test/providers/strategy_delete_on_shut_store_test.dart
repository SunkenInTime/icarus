import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/library_store/library_migration.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/store_library.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/pinned_items_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:path/path.dart' as path;

import '../library_store/gated_engine.dart';

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late ProviderContainer container;
  late MemoryStorage storage;
  late LibraryStore store;
  late CommitGate gate;

  StrategyData strategy(String id) => StrategyData(
        id: id,
        name: id,
        mapData: MapValue.ascent,
        versionNumber: Settings.versionNumber,
        lastEdited: DateTime.utc(2026),
        folderID: null,
        pages: const [],
      );

  Future<LibraryStore> open(StorageEngine engine) async =>
      switch (await LibraryStore.open(engine, canRead: appCanRead)) {
        StoreOpened(:final store) => store,
        StoreNotOpened(:final problem) => fail('$problem'),
      };

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('delete_on_shut_store');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, (_) async => dir.path);
    Hive.init(dir.path);
    if (!Hive.isAdapterRegistered(20)) registerIcarusAdapters(Hive);
    final strategies =
        await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<int>(HiveBoxNames.pinnedItemsBox);
    await strategies.put('a', strategy('a'));
    await strategies.put('b', strategy('b'));
    final images = Directory(path.join(dir.path, 'a', 'images'));
    await images.create(recursive: true);
    await File(path.join(images.path, 'picture.png')).writeAsBytes([1]);

    storage = MemoryStorage();
    gate = CommitGate();
    store = await open(GatedEngine(MemoryEngine(storage), gate));
    expect(
      await migrateLibraryIntoStore(
        store,
        strategies: [...strategies.values],
        folders: const [],
      ),
      isA<MigrationFinishedNow>(),
    );
    LocalLibrary.source = LibraryInStore(
      switch (await StoreLibrary.load(store, lost: (_) {})) {
        StoreLibraryLoaded(:final library) => library,
        StoreLibraryNotLoaded(:final why) => fail(why),
      },
    );
    container = ProviderContainer(overrides: [
      libraryWorkspaceProvider.overrideWith(_LocalWorkspace.new),
    ]);
    await container.read(pinnedItemsProvider.notifier).togglePin('a');
  });

  tearDown(() async {
    container.dispose();
    LocalLibrary.source = const LibraryInHive();
    await store.close();
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null);
    await dir.delete(recursive: true);
  });

  test(
      'a delete queued behind a save whose answer is lost fails, and the '
      'strategy keeps its pictures, its pin and its place in the store',
      () async {
    gate.doubtNext = true;

    final saving = const LocalLibrary().saveStrategyFields(
      const LocalLibrary().storedStrategy('b')!.copyWith(name: 'Saved'),
    );
    final deleting = container
        .read(strategyProvider.notifier)
        .deleteStrategy('a', source: StrategySource.local);

    await expectLater(deleting, throwsA(anything));
    await saving;
    expect(Directory(path.join(dir.path, 'a', 'images')).existsSync(), isTrue);
    expect(container.read(pinnedItemsProvider), contains('a'));
    await store.close();
    final back = await open(MemoryEngine(storage));
    addTearDown(back.close);
    expect(back.summaryOf('a'), isNotNull);
  });
}

class _LocalWorkspace extends LibraryWorkspaceNotifier {
  @override
  LibraryWorkspace build() => LibraryWorkspace.local;
}
