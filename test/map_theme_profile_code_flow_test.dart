import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/services/map_theme_profile_code.dart';
import 'package:icarus/widgets/map_theme_settings_section.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String clipboardText;
  late bool clipboardFails;
  late ProviderContainer container;

  final nightMarket = MapThemePalette(
    baseColorValue: 0xFF141B2D,
    detailColorValue: 0xFF6C8EBF,
    highlightColorValue: 0xFFE05C9C,
  );
  final havenDusk = MapThemePalette(
    baseColorValue: 0xFF2A1B2E,
    detailColorValue: 0xFFC78B5A,
    highlightColorValue: 0xFF6FD3C4,
  );

  setUpAll(() {
    registerIcarusAdapters(Hive);
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('icarus-profile-code-');
    Hive.init(tempDir.path);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await MapThemeProfilesProvider.bootstrap();

    clipboardText = '';
    clipboardFails = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.getData':
          if (clipboardFails) {
            throw PlatformException(code: 'denied');
          }
          return <String, dynamic>{'text': clipboardText};
        case 'Clipboard.setData':
          final arguments = call.arguments as Map<dynamic, dynamic>;
          clipboardText = arguments['text'] as String? ?? '';
        case 'Clipboard.hasStrings':
          return <String, bool>{'value': clipboardText.isNotEmpty};
      }
      return null;
    });

    container = ProviderContainer();
    await container
        .read(mapThemeProfilesProvider.notifier)
        .createProfile(name: 'Night Market', palette: nightMarket);
  });

  tearDown(() async {
    container.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    await Hive.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  // Flip to false to take the section down while the app (and its toasts)
  // stay up, the way closing Settings does.
  final showSection = ValueNotifier(true);

  Future<void> pumpSection(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    showSection.value = true;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ToastificationWrapper(
          child: ShadApp(
            home: Scaffold(
              body: ValueListenableBuilder(
                valueListenable: showSection,
                builder: (context, show, _) => show
                    ? const SingleChildScrollView(
                        child: MapThemeSettingsSection(),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  // Hive and the clipboard answer on the real event loop.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> finishToasts(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  }

  testWidgets('Copy profile code puts the profile on the clipboard',
      (tester) async {
    await pumpSection(tester);

    await tester.tap(find.byIcon(LucideIcons.ellipsisVertical).last);
    await settle(tester);
    await tester.tap(find.text('Copy profile code'));
    await settle(tester);

    final copied = MapThemeProfileCode.parse(clipboardText);
    expect(copied, isA<MapThemeProfileCodeValid>());
    copied as MapThemeProfileCodeValid;
    expect(copied.name, 'Night Market');
    expect(MapThemePalette.fromJson(copied.colors), nightMarket);
    expect(find.text('Profile code copied'), findsOneWidget);
    await finishToasts(tester);
  });

  testWidgets('a code on the clipboard imports in two clicks', (tester) async {
    clipboardText = 'try ours: '
        '${MapThemeProfileCode.encode(name: 'Haven Dusk', colors: havenDusk.toJson())}';
    await pumpSection(tester);

    await tester.tap(find.text('Import profile code'));
    await settle(tester);
    expect(find.text('Pasted from your clipboard.'), findsOneWidget);
    expect(find.text('Haven Dusk'), findsOneWidget);

    // Start the Hive write on the real event loop so it can finish.
    await tester.runAsync(() async {
      await tester.tap(find.text('Add profile'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await settle(tester);

    final added = Hive.box<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox)
        .values
        .where((profile) => profile.name == 'Haven Dusk')
        .single;
    expect(added.palette, havenDusk);
    expect(added.isBuiltIn, isFalse);
    expect(find.text('Haven Dusk added'), findsOneWidget);
    // The new profile lands after the ones already there.
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester.getTopLeft(find.text('Haven Dusk')).dy,
      greaterThan(tester.getTopLeft(find.text('Night Market')).dy),
    );
    await finishToasts(tester);
  });

  testWidgets('Use it still applies the profile after Settings closes',
      (tester) async {
    // Applying a theme marks the strategy unsaved; this test has no
    // strategy box for an autosave to write to.
    await tester.runAsync(() => container
        .read(appPreferencesProvider.notifier)
        .setAutosaveEnabled(false));
    container.read(strategyProvider.notifier).setFromState(
          const StrategyState(
            strategyId: 'strategy-id',
            strategyName: 'Split execute',
            storageDirectory: null,
            isOpen: true,
          ),
        );
    clipboardText = MapThemeProfileCode.encode(
        name: 'Haven Dusk', colors: havenDusk.toJson());
    await pumpSection(tester);

    await tester.tap(find.text('Import profile code'));
    await settle(tester);
    await tester.runAsync(() async {
      await tester.tap(find.text('Add profile'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await settle(tester);

    showSection.value = false;
    // Let the toast finish sliding in.
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byType(MapThemeSettingsSection), findsNothing);

    await tester.tap(find.text('Use it'));
    await tester.pump();
    final added = container
        .read(mapThemeProfilesProvider)
        .profiles
        .singleWhere((profile) => profile.name == 'Haven Dusk');
    expect(container.read(strategyThemeProvider).profileId, added.id);
    await finishToasts(tester);
  });

  testWidgets('a clipboard that cannot be read still opens the dialog',
      (tester) async {
    clipboardFails = true;
    await pumpSection(tester);

    await tester.tap(find.text('Import profile code'));
    await settle(tester);

    expect(find.text('Import profile code'), findsWidgets);
    expect(find.text('The colors show here once you paste a code.'),
        findsOneWidget);
  });

  testWidgets('colors you already have cannot be added twice', (tester) async {
    clipboardText =
        MapThemeProfileCode.encode(name: 'Copy', colors: nightMarket.toJson());
    await pumpSection(tester);

    await tester.tap(find.text('Import profile code'));
    await settle(tester);

    expect(
      find.text('You already have these colors as “Night Market”.'),
      findsOneWidget,
    );
    final addButton = tester.widget<ShadButton>(
      find.ancestor(
        of: find.text('Add profile'),
        matching: find.byType(ShadButton),
      ),
    );
    expect(addButton.enabled, isFalse);
  });

  testWidgets('pasting something else explains itself', (tester) async {
    await pumpSection(tester);

    await tester.tap(find.text('Import profile code'));
    await settle(tester);
    expect(find.text('The colors show here once you paste a code.'),
        findsOneWidget);

    await tester.enterText(find.byType(EditableText), 'hello');
    await tester.pump();
    expect(find.text("That isn't an Icarus profile code."), findsOneWidget);

    // The longest message wraps onto a second line instead of clipping.
    await tester.enterText(
      find.byType(EditableText),
      '${MapThemeProfileCode.prefix}eyJ2IjoyfQ',
    );
    await tester.pump();
    const newer =
        'This code is from a newer version of Icarus. Update Icarus to import it.';
    expect(tester.getSize(find.text(newer)).height, greaterThan(16));
  });
}
