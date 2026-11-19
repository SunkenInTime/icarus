import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/user_preferences_provider.dart';

void main() {
  late Directory tempDir;

  setUpAll(() {
    registerIcarusAdapters(Hive);
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('icarus-default-colors-');
    Hive.init(tempDir.path);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test(
      'a store holding an earlier Default takes the current colors at launch, '
      'and a custom profile in those colors keeps them', () async {
    // What every store up to 4.x holds: Default with the map art's own wall
    // colour. A player who liked it may have saved the same colours as their
    // own profile.
    final earlierDefault = MapThemePalette(
      baseColorValue: 0xFF271406,
      detailColorValue: 0xFFB27C40,
      highlightColorValue: 0xFFF08234,
    );
    final profiles =
        Hive.box<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    final custom = MapThemeProfile(
      id: 'custom-id',
      name: 'Old walls',
      palette: earlierDefault,
      isBuiltIn: false,
    );
    await profiles.putAll({
      MapThemeProfilesProvider.immutableDefaultProfileId: MapThemeProfile(
        id: MapThemeProfilesProvider.immutableDefaultProfileId,
        name: 'Default',
        palette: earlierDefault,
        isBuiltIn: true,
      ),
      custom.id: custom,
    });

    await MapThemeProfilesProvider.bootstrap();

    expect(
      profiles.get(MapThemeProfilesProvider.immutableDefaultProfileId)!.palette,
      MapThemeProfilesProvider.immutableDefaultPalette,
    );
    expect(profiles.get(custom.id)!.palette, earlierDefault);

    // A strategy left on Default draws in what the store now holds.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(strategyThemeProvider.notifier).fromStrategy(
          profileId: MapThemeProfilesProvider.immutableDefaultProfileId,
        );
    expect(
      container.read(effectiveMapThemePaletteProvider),
      MapThemeProfilesProvider.immutableDefaultPalette,
    );
  });
}
