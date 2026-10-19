import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/hive/hive_adapters.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/user_preferences_provider.dart';

/// Writes AppPreferences the way builds before transparent screenshots and
/// videos did, so fields 21 and 22 are absent on disk.
class _PreTransparentPreferencesAdapter extends TypeAdapter<AppPreferences> {
  @override
  final typeId = 28;

  @override
  AppPreferences read(BinaryReader reader) => throw UnimplementedError();

  @override
  void write(BinaryWriter writer, AppPreferences obj) {
    writer
      ..writeByte(3)
      ..writeByte(0)
      ..write(obj.defaultThemeProfileIdForNewStrategies)
      ..writeByte(19)
      ..write(obj.backgroundDotOpacity)
      ..writeByte(20)
      ..write(obj.welcomeTourSeen);
  }
}

void main() {
  late Directory tempDir;

  setUpAll(() => registerIcarusAdapters(Hive));

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('icarus-transparent-shot-');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('preferences saved before the options existed export solid', () async {
    Hive.registerAdapter(_PreTransparentPreferencesAdapter(), override: true);
    var box =
        await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await box.put(
      MapThemeProfilesProvider.appPreferencesSingletonKey,
      AppPreferences(
        defaultThemeProfileIdForNewStrategies: 'profile-from-old-build',
        backgroundDotOpacity: 0.4,
        welcomeTourSeen: true,
      ),
    );
    await Hive.close();

    Hive.registerAdapter(AppPreferencesAdapter(), override: true);
    box = await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    final restored =
        box.get(MapThemeProfilesProvider.appPreferencesSingletonKey)!;
    expect(restored.defaultThemeProfileIdForNewStrategies,
        'profile-from-old-build');
    expect(restored.backgroundDotOpacity, 0.4);
    expect(restored.welcomeTourSeen, isTrue);
    expect(restored.transparentScreenshotBackground, isFalse);
    expect(restored.transparentVideoBackground, isFalse);

    // Once turned on, each stays on across a restart.
    var container = ProviderContainer();
    await container
        .read(appPreferencesProvider.notifier)
        .setTransparentScreenshotBackground(true);
    await container
        .read(appPreferencesProvider.notifier)
        .setTransparentVideoBackground(true);
    container.dispose();
    await Hive.close();
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      container.read(appPreferencesProvider).transparentScreenshotBackground,
      isTrue,
    );
    expect(
      container.read(appPreferencesProvider).transparentVideoBackground,
      isTrue,
    );
  });
}
