import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/hive/hive_adapters.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/services/archive_manifest.dart';

/// Writes AppPreferences the way builds before this setting did, so field 24
/// is absent on disk.
class _PreViewConeOpacityAdapter extends TypeAdapter<AppPreferences> {
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
  late Directory tempDir;

  setUpAll(() {
    registerIcarusAdapters(Hive);
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('icarus-cone-opacity-');
    Hive.init(tempDir.path);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('preferences saved before the setting draw cones as they were',
      () async {
    await Hive.close();
    Hive.registerAdapter(_PreViewConeOpacityAdapter(), override: true);
    var box =
        await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await box.put(
      MapThemeProfilesProvider.appPreferencesSingletonKey,
      AppPreferences(defaultThemeProfileIdForNewStrategies: 'old-profile'),
    );
    await box.close();
    Hive.registerAdapter(AppPreferencesAdapter(), override: true);

    box = await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    final read = box.get(MapThemeProfilesProvider.appPreferencesSingletonKey)!;
    expect(read.defaultThemeProfileIdForNewStrategies, 'old-profile');
    expect(read.viewConeOpacity, 1.0);
  });

  test('a backup keeps the setting, and an old backup has none', () {
    const globals = ArchiveGlobals(
      themeProfiles: [],
      defaultThemeProfileIdForNewStrategies: null,
      showSpawnBarrier: null,
      showUltOrbs: null,
      showRegionNames: null,
      backgroundDotOpacity: null,
      viewConeOpacity: 0.35,
      customColorValues: [],
      favoriteAgents: [],
    );
    final json = globals.toJson();
    expect(ArchiveGlobals.fromJson(json).viewConeOpacity, 0.35);

    (json['appPreferences'] as Map).remove('viewConeOpacity');
    expect(ArchiveGlobals.fromJson(json).viewConeOpacity, isNull);
  });

  test('the setting can never hide cones completely', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(appPreferencesProvider.notifier).setViewConeOpacity(0);
    expect(
      container.read(appPreferencesProvider).viewConeOpacity,
      AppPreferences.minViewConeOpacity,
    );
  });
}
