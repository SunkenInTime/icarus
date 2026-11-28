import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import '../opens_now_support.dart';

final class UnitHarness {
  UnitHarness._(this.container);

  final ProviderContainer container;

  Future<void> settle() async {
    for (var turn = 0; turn < 6; turn++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> dispose() async {
    container.read(strategyProvider.notifier).cancelPendingSave();
  }
}

final _unitHives = <Directory>[];

Future<Directory> openUnitHive() async {
  CoordinateSystem(playAreaSize: const Size(1920, 1080));
  final directory = await Directory.systemTemp.createTemp('icarus-units-');
  _unitHives.add(directory);
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

Future<void> closeUnitHive() async {
  await Hive.close();
  for (final directory in [..._unitHives]) {
    _unitHives.remove(directory);
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

Future<UnitHarness> openInEditor(
  ProviderContainer container,
  StrategyData strategy,
) async {
  final migrated = StrategyMigrator.migrateToCurrentVersion(strategy);
  await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
      .put(migrated.id, migrated);
  final harness = UnitHarness._(container);
  expect(
    await container.read(strategyProvider.notifier).loadFromHive(migrated.id),
    isTrue,
  );
  await harness.settle();
  return harness;
}
