import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/services/discord_presence_service.dart';
import 'package:icarus/widgets/settings_tab.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

Future<void> _openDefaults(
  WidgetTester tester, {
  required PlatformPolicy policy,
  required bool discordPresenceSupported,
}) async {
  tester.view.physicalSize = const Size(1440, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // The test font's wide glyphs overflow the dialog's buttons at full size.
  tester.platformDispatcher.textScaleFactorTestValue = 0.5;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        platformPolicyProvider.overrideWithValue(policy),
        discordPresenceSupportedProvider
            .overrideWithValue(discordPresenceSupported),
        authProvider.overrideWith(_SignedOut.new),
      ],
      child: const ShadApp(home: Scaffold(body: SettingsTab())),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('Defaults'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  late Directory tempDir;

  setUpAll(() {
    registerIcarusAdapters(Hive);
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('icarus-settings-');
    Hive.init(tempDir.path);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await MapThemeProfilesProvider.bootstrap();
  });

  tearDown(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  testWidgets('the web beta has neither toggle, and no card to hold them',
      (tester) async {
    await _openDefaults(
      tester,
      policy: PlatformPolicy.webBeta,
      discordPresenceSupported: false,
    );

    expect(find.text('Autosave'), findsNothing);
    expect(find.text('Discord Rich Presence'), findsNothing);
    expect(find.text('Workspace behavior'), findsNothing);
    expect(find.text('Workspace map visibility'), findsOneWidget);
  });

  testWidgets('Windows has both toggles', (tester) async {
    await _openDefaults(
      tester,
      policy: PlatformPolicy.desktop,
      discordPresenceSupported: true,
    );

    // One in the navigation rail, one on the toggle.
    expect(find.text('Autosave'), findsNWidgets(2));
    expect(find.text('Discord Rich Presence'), findsOneWidget);
  });

  testWidgets('a desktop without Discord support keeps Autosave',
      (tester) async {
    await _openDefaults(
      tester,
      policy: PlatformPolicy.desktop,
      discordPresenceSupported: false,
    );

    expect(find.text('Autosave'), findsNWidgets(2));
    expect(find.text('Workspace behavior'), findsOneWidget);
    expect(find.text('Discord Rich Presence'), findsNothing);
  });
}
