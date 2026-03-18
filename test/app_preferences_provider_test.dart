import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/app_preferences_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/map_theme_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

bool _adaptersRegistered = false;

class _NoopStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() {
    return StrategyState(
      isSaved: true,
      stratName: 'test strategy',
      id: 'strategy-id',
      storageDirectory: null,
      activePageId: 'page-1',
    );
  }

  @override
  void setUnsaved() {
    state = state.copyWith(isSaved: false);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('App preferences', () {
    late Directory tempDir;
    late ProviderContainer container;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('icarus-app-prefs-');
      Hive.init(tempDir.path);
      if (!_adaptersRegistered) {
        registerIcarusAdapters(Hive);
        _adaptersRegistered = true;
      }
      await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
      await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
      await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
      await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
      await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
      await MapThemeProfilesProvider.bootstrap();
      container = ProviderContainer();
    });

    tearDown(() async {
      container.dispose();
      await Hive.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('provider persists global preferences across containers', () async {
      final notifier = container.read(appPreferencesProvider.notifier);
      await notifier.setShowSpawnBarrier(true);
      await notifier.setShowRegionNames(true);
      await notifier.setShowUltOrbs(true);
      await notifier.setDefaultAgentSizeForNewStrategies(
        Settings.agentSizeMax,
      );
      await notifier.setDefaultAbilitySizeForNewStrategies(
        Settings.abilitySizeMin,
      );

      final reloadedContainer = ProviderContainer();
      addTearDown(reloadedContainer.dispose);

      final reloaded = reloadedContainer.read(appPreferencesProvider);
      expect(reloaded.showSpawnBarrier, isTrue);
      expect(reloaded.showRegionNames, isTrue);
      expect(reloaded.showUltOrbs, isTrue);
      expect(
        reloaded.defaultAgentSizeForNewStrategies,
        Settings.agentSizeMax,
      );
      expect(
        reloaded.defaultAbilitySizeForNewStrategies,
        Settings.abilitySizeMin,
      );
    });

    test('new strategies use persisted default sizes', () async {
      await container
          .read(appPreferencesProvider.notifier)
          .setDefaultAgentSizeForNewStrategies(Settings.agentSizeMin);
      await container
          .read(appPreferencesProvider.notifier)
          .setDefaultAbilitySizeForNewStrategies(Settings.abilitySizeMax);

      final strategyId = await container
          .read(strategyProvider.notifier)
          .createNewStrategy('Defaults Test');
      final strategy =
          Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(strategyId)!;

      expect(strategy.pages.single.settings.agentSize, Settings.agentSizeMin);
      expect(
        strategy.pages.single.settings.abilitySize,
        Settings.abilitySizeMax,
      );
      expect(strategy.strategySettings.agentSize, Settings.agentSizeMin);
      expect(strategy.strategySettings.abilitySize, Settings.abilitySizeMax);
    });
  });

  group('Dirty state behavior', () {
    test('strategy settings updates mark the strategy unsaved', () {
      final container = ProviderContainer(
        overrides: [
          strategyProvider.overrideWith(_NoopStrategyProvider.new),
        ],
      );
      addTearDown(container.dispose);

      container.read(strategySettingsProvider.notifier).updateAgentSize(42);
      expect(container.read(strategyProvider).isSaved, isFalse);
    });

    test('reset action state does not dirty the strategy', () {
      final container = ProviderContainer(
        overrides: [
          strategyProvider.overrideWith(_NoopStrategyProvider.new),
        ],
      );
      addTearDown(container.dispose);

      container.read(actionProvider.notifier).resetActionState();
      expect(container.read(strategyProvider).isSaved, isTrue);
    });
  });
}
