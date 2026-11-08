import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/widgets/settings_tab.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

const _noMatch = 'No shortcuts match that search.';
const _altRow = 'Snap to map lines while dragging';

void main() {
  late Directory tempDir;

  setUpAll(() {
    registerIcarusAdapters(Hive);
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('icarus-keybinds-');
    Hive.init(tempDir.path);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await MapThemeProfilesProvider.bootstrap();
  });

  tearDown(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  testWidgets('a search only the Alt row matches shows that row alone', (
    tester,
  ) async {
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
    await tester.tap(find.text('Keybinds'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    for (final query in ['alt', 'snap']) {
      await tester.enterText(find.byType(TextField), query);
      await tester.pump();
      expect(find.text(_altRow), findsOneWidget, reason: query);
      expect(find.text(_noMatch), findsNothing, reason: query);
    }

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump();
    expect(find.text(_altRow), findsNothing);
    expect(find.text(_noMatch), findsOneWidget);
  });
}
