import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/widgets/settings_tab.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

Future<ProviderContainer> _openSettings(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1440, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.platformDispatcher.textScaleFactorTestValue = 0.5;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [authProvider.overrideWith(_SignedOut.new)],
      child: const ShadApp(home: Scaffold(body: SettingsTab())),
    ),
  );
  await tester.pump();
  return ProviderScope.containerOf(tester.element(find.byType(SettingsTab)));
}

Finder _slider(int index) => find.byType(Slider).at(index);

void main() {
  late Directory tempDir;

  setUpAll(() {
    registerIcarusAdapters(Hive);
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('icarus-marker-undo-');
    Hive.init(tempDir.path);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await MapThemeProfilesProvider.bootstrap();
  });

  tearDown(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  for (final (name, index, start, read) in [
    (
      'ability',
      1,
      Settings.abilitySize,
      (StrategySettings s) => s.abilitySize,
    ),
    (
      'agent',
      0,
      Settings.agentSize + 1,
      (StrategySettings s) => s.agentSize,
    ),
  ]) {
    testWidgets(
        'undoing a $name marker size change returns exactly the size it '
        'started at, $start, which is not on one of the slider\'s steps',
        (tester) async {
      final container = await _openSettings(tester);
      final settings = container.read(strategySettingsProvider.notifier);
      if (index == 0) {
        settings.updateAgentSize(start);
      } else {
        settings.updateAbilitySize(start);
      }
      await tester.pump();
      expect(read(container.read(strategySettingsProvider)), start);

      await tester.drag(_slider(index), const Offset(80, 0));
      await tester.pumpAndSettle();
      expect(read(container.read(strategySettingsProvider)), isNot(start));

      container.read(actionProvider.notifier).undoAction();
      await tester.pump();

      expect(read(container.read(strategySettingsProvider)), start);
    });
  }
}
