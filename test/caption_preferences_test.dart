import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/hive/hive_adapters.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/user_preferences_provider.dart';

/// Writes AppPreferences the way builds before captions did, so their fields
/// are absent on disk.
class _PreCaptionsAdapter extends TypeAdapter<AppPreferences> {
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
    tempDir = await Directory.systemTemp.createTemp('icarus-captions-prefs-');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.close();
    Hive.registerAdapter(AppPreferencesAdapter(), override: true);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('preferences saved before captions show them', () async {
    Hive.registerAdapter(_PreCaptionsAdapter(), override: true);
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
    expect(read.showCaptions, isTrue);
    expect(read.includeScreenshotCaptions, isFalse);
    expect(read.includeVideoCaptions, isFalse);
  });
}
