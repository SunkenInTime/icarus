import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/library_store/hive_reads.dart';
import 'package:icarus/library_store/library_box_writes.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus_library/icarus_library.dart' hide UserAction;
import '../opens_now_support.dart';

final class UnitHarness {
  UnitHarness._(this.container, this.mirror, this.store);

  final ProviderContainer container;
  final StoreMirror mirror;
  final LibraryStore store;

  Future<void> settle() async {
    for (var turn = 0; turn < 6; turn++) {
      await Future<void>.delayed(Duration.zero);
      await mirror.drained();
    }
  }

  Future<void> dispose() async {
    container.read(strategyProvider.notifier).cancelPendingSave();
    LocalLibrary.follower = null;
    await store.close();
  }
}

Future<Directory> openUnitHive() async {
  CoordinateSystem(playAreaSize: const Size(1920, 1080));
  final directory = await Directory.systemTemp.createTemp('icarus-units-');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => directory.path,
  );
  Hive.init(directory.path);
  if (!Hive.isAdapterRegistered(20)) registerIcarusAdapters(Hive);
  await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
  await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
  await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
  await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
  await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
  await Hive.openBox<int>(HiveBoxNames.pinnedItemsBox);
  await Hive.openBox<dynamic>(HiveBoxNames.strategyOutboxBox);
  await Hive.openBox<dynamic>(HiveBoxNames.cloudMediaOutboxBox);
  return directory;
}

Future<UnitHarness> openInEditor(
  ProviderContainer container,
  StrategyData strategy, {
  bool follow = true,
  StorageEngine Function(StorageEngine memory)? engine,
  Future<void> Function()? betweenSteps,
}) async {
  final migrated = StrategyMigrator.migrateToCurrentVersion(strategy);
  await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
      .put(migrated.id, migrated);
  final mirror = StoreMirror(
    reads: HiveReads(),
    betweenAnimations: betweenSteps ?? () => Future<void>.value(),
  );
  LocalLibrary.follower = mirror;
  final store = switch (await LibraryStore.open(
    (engine ?? (memory) => memory)(MemoryEngine(MemoryStorage())),
    canRead: appCanRead,
  )) {
    StoreOpened(:final store) => store,
    StoreNotOpened(:final problem) => fail('$problem'),
  };
  if (follow) {
    final writes = LibraryBoxWrites();
    await mirror.copyThenFollow(store, writes: writes);
    await writes.stop();
  }
  final harness = UnitHarness._(container, mirror, store);
  expect(
    await container.read(strategyProvider.notifier).loadFromHive(migrated.id),
    isTrue,
  );
  await harness.settle();
  return harness;
}
