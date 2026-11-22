import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_migrator.dart';

import 'library_rows/generated_strategies.dart';

StrategyData named(String id, String name) =>
    StrategyMigrator.migrateToCurrentVersion(
      generatedStrategy(Optionals.unset).copyWith(id: id, name: name),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late ProviderContainer container;
  setUpAll(() {
    container = ProviderContainer();
    appProviderContainer = container;
  });
  tearDownAll(() => container.dispose());
  setUp(() async {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
    directory = await Directory.systemTemp.createTemp('icarus-open-by-id-');
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
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Box<StrategyData> strategies() =>
      Hive.box<StrategyData>(HiveBoxNames.strategiesBox);

  test('a strategy stored under a key that is not its id opens by its id',
      () async {
    await strategies().put('auto-key-0', named('kept-id', 'Stored by add'));
    final opened =
        await container.read(strategyProvider.notifier).loadFromHive('kept-id');
    expect(opened, isTrue);
    expect(container.read(strategyProvider).strategyName, 'Stored by add');
  });

  test('of two records sharing an id, opening takes the first the box holds',
      () async {
    await strategies().put('a-first-key', named('shared', 'First record'));
    await strategies().put('shared', named('shared', 'Record keyed by id'));
    expect(strategies().values.first.name, 'First record');
    final opened =
        await container.read(strategyProvider.notifier).loadFromHive('shared');
    expect(opened, isTrue);
    expect(container.read(strategyProvider).strategyName, 'First record');
  });
}
