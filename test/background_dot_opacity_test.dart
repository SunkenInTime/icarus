import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/hive/hive_adapters.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/widgets/dot_painter.dart';
import 'package:icarus/widgets/hover_dot_grid.dart';

/// Writes AppPreferences the way builds before the dot setting did: only the
/// fields they knew about, so field 19 is absent on disk.
class _PreDotOpacityPreferencesAdapter extends TypeAdapter<AppPreferences> {
  @override
  final typeId = 28;

  @override
  AppPreferences read(BinaryReader reader) => throw UnimplementedError();

  @override
  void write(BinaryWriter writer, AppPreferences obj) {
    writer
      ..writeByte(2)
      ..writeByte(0)
      ..write(obj.defaultThemeProfileIdForNewStrategies)
      ..writeByte(1)
      ..write(obj.autosaveEnabled);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() {
    registerIcarusAdapters(Hive);
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('icarus-dot-opacity-');
    Hive.init(tempDir.path);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('preferences saved before the setting existed keep full dots', () async {
    await Hive.close();
    Hive.registerAdapter(_PreDotOpacityPreferencesAdapter(), override: true);
    var box =
        await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await box.put(
      MapThemeProfilesProvider.appPreferencesSingletonKey,
      AppPreferences(
        defaultThemeProfileIdForNewStrategies: 'profile-from-old-build',
        autosaveEnabled: false,
      ),
    );
    await Hive.close();

    Hive.registerAdapter(AppPreferencesAdapter(), override: true);
    box = await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    final restored =
        box.get(MapThemeProfilesProvider.appPreferencesSingletonKey)!;

    expect(restored.defaultThemeProfileIdForNewStrategies,
        'profile-from-old-build');
    expect(restored.autosaveEnabled, isFalse);
    expect(restored.backgroundDotOpacity, 1.0);
  });

  test('dot opacity survives a provider restart and stays in range', () async {
    var container = ProviderContainer();
    final preferences = container.read(appPreferencesProvider.notifier);

    await preferences.setBackgroundDotOpacity(0.35);
    await Hive.box<AppPreferences>(HiveBoxNames.appPreferencesBox).flush();
    container.dispose();

    container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(appPreferencesProvider).backgroundDotOpacity, 0.35);

    await container
        .read(appPreferencesProvider.notifier)
        .setBackgroundDotOpacity(1.4);
    expect(container.read(appPreferencesProvider).backgroundDotOpacity, 1.0);
  });

  testWidgets('the dot grid follows the opacity setting', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const Center(
          child: SizedBox(width: 120, height: 80, child: DotGrid()),
        ),
      ),
    );
    final grid = find.descendant(
      of: find.byType(DotGrid),
      matching: find.byType(CustomPaint),
    );
    expect(
      tester.renderObject(grid),
      paints..something((method, _) => method == #drawPoints),
    );

    await tester.runAsync(() => container
        .read(appPreferencesProvider.notifier)
        .setBackgroundDotOpacity(0));
    await tester.pump();
    expect(tester.renderObject(grid), paintsNothing);
  });

  testWidgets('a hidden library grid ignores the mouse', (tester) async {
    Future<bool> hoverSchedulesFrames(double opacity) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.runAsync(() => container
          .read(appPreferencesProvider.notifier)
          .setBackgroundDotOpacity(opacity));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(width: 200, height: 200, child: HoverDotGrid()),
          ),
        ),
      );
      await tester.pump();

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(50, 50));
      await mouse.moveTo(const Offset(80, 80));
      final scheduled = tester.binding.hasScheduledFrame;
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
      return scheduled;
    }

    expect(await hoverSchedulesFrames(1), isTrue);
    expect(await hoverSchedulesFrames(0), isFalse);
  });
}
