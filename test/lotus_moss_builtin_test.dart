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
    tempDir = await Directory.systemTemp.createTemp('icarus-lotus-moss-');
    Hive.init(tempDir.path);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('a store from before Lotus Moss gains it at launch and keeps the rest',
      () async {
    // What a 4.6.3 store holds: the two older built-ins, a custom profile,
    // and that custom profile as the default for new strategies.
    final profiles =
        Hive.box<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    final custom = MapThemeProfile(
      id: 'custom-id',
      name: 'Tournament',
      palette: MapThemePalette(
        baseColorValue: 0xFF0F172A,
        detailColorValue: 0xFF38BDF8,
        highlightColorValue: 0xFFF97316,
      ),
      isBuiltIn: false,
    );
    await profiles.putAll({
      MapThemeProfilesProvider.immutableDefaultProfileId:
          MapThemeProfilesProvider.immutableDefaultProfile,
      MapThemeProfilesProvider.immutableValorantProfileId:
          MapThemeProfilesProvider.immutableValorantProfile,
      custom.id: custom,
    });
    await Hive.box<AppPreferences>(HiveBoxNames.appPreferencesBox).put(
      MapThemeProfilesProvider.appPreferencesSingletonKey,
      AppPreferences(defaultThemeProfileIdForNewStrategies: custom.id),
    );

    await MapThemeProfilesProvider.bootstrap();

    final lotus =
        profiles.get(MapThemeProfilesProvider.immutableLotusMossProfileId)!;
    expect(lotus.name, 'Lotus Moss');
    expect(lotus.isBuiltIn, isTrue);
    expect(lotus.palette, MapThemeProfilesProvider.immutableLotusMossPalette);
    expect(profiles.get(custom.id)!.palette, custom.palette);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final state = container.read(mapThemeProfilesProvider);
    expect(
      state.profiles.map((profile) => profile.name),
      ['Default', 'Valorant', 'Lotus Moss', 'Tournament'],
    );
    expect(state.defaultProfileIdForNewStrategies, custom.id);
  });

  test('Lotus Moss is a built-in: it cannot be renamed, recolored, or deleted',
      () async {
    await MapThemeProfilesProvider.bootstrap();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(mapThemeProfilesProvider.notifier);
    const id = MapThemeProfilesProvider.immutableLotusMossProfileId;

    expect(
        await notifier.renameProfile(profileId: id, newName: 'Moss'), isFalse);
    expect(
      await notifier.updateProfilePalette(
        profileId: id,
        palette: MapThemeProfilesProvider.immutableDefaultPalette,
      ),
      isFalse,
    );
    await notifier.deleteProfile(id);

    final lotus = container
        .read(mapThemeProfilesProvider)
        .profiles
        .singleWhere((profile) => profile.id == id);
    expect(lotus.name, 'Lotus Moss');
    expect(lotus.palette, MapThemeProfilesProvider.immutableLotusMossPalette);
  });

  test('a strategy set to Lotus Moss draws in its colors', () async {
    await MapThemeProfilesProvider.bootstrap();
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(strategyThemeProvider.notifier).fromStrategy(
          profileId: MapThemeProfilesProvider.immutableLotusMossProfileId,
        );

    expect(
      container.read(effectiveMapThemePaletteProvider),
      MapThemeProfilesProvider.immutableLotusMossPalette,
    );
  });
}
