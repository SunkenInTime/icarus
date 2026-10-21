import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/user_preferences_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() {
    registerIcarusAdapters(Hive);
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('icarus-default-theme-');
    Hive.init(tempDir.path);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await MapThemeProfilesProvider.bootstrap();
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('the default theme survives changing another preference', () async {
    var container = ProviderContainer();
    // The app reads its preferences at startup, before any theme is picked.
    container.read(appPreferencesProvider);

    await container
        .read(mapThemeProfilesProvider.notifier)
        .setDefaultProfileForNewStrategies(
            MapThemeProfilesProvider.immutableValorantProfileId);
    await container.read(appPreferencesProvider.notifier).setAutosaveEnabled(
          false,
        );
    await container.read(appPreferencesProvider.notifier).flushPendingWrites();
    container.dispose();

    container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      container.read(mapThemeProfilesProvider).defaultProfileIdForNewStrategies,
      MapThemeProfilesProvider.immutableValorantProfileId,
    );
    expect(container.read(appPreferencesProvider).autosaveEnabled, isFalse);
  });

  test('deleting the default profile resets it for later writes too', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final themes = container.read(mapThemeProfilesProvider.notifier);
    final custom = await themes.createProfile(
      name: 'Night',
      palette: MapThemeProfilesProvider.immutableValorantPalette,
    );
    await themes.setDefaultProfileForNewStrategies(custom!.id);
    expect(
      container
          .read(appPreferencesProvider)
          .defaultThemeProfileIdForNewStrategies,
      custom.id,
    );

    await themes.deleteProfile(custom.id);
    expect(
      container
          .read(appPreferencesProvider)
          .defaultThemeProfileIdForNewStrategies,
      MapThemeProfilesProvider.immutableDefaultProfileId,
    );

    // A later preference write keeps the reset default on disk.
    await container.read(appPreferencesProvider.notifier).setAutosaveEnabled(
          false,
        );
    await container.read(appPreferencesProvider.notifier).flushPendingWrites();
    expect(
      Hive.box<AppPreferences>(HiveBoxNames.appPreferencesBox)
          .get(MapThemeProfilesProvider.appPreferencesSingletonKey)!
          .defaultThemeProfileIdForNewStrategies,
      MapThemeProfilesProvider.immutableDefaultProfileId,
    );
  });
}
