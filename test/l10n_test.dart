import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/hive/hive_adapters.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/user_preferences_provider.dart';

/// Writes AppPreferences the way builds before languages did, with no
/// language field on disk.
class _PreLanguageAdapter extends TypeAdapter<AppPreferences> {
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

Map<String, String> _messages(String language) {
  final arb = jsonDecode(File('lib/l10n/app_$language.arb').readAsStringSync())
      as Map<String, dynamic>;
  return {
    for (final entry in arb.entries)
      if (!entry.key.startsWith('@')) entry.key: entry.value as String,
  };
}

/// The names a message fills in: `{count}`, `{name}`.
Set<String> _placeholders(String message) => {
      for (final match
          in RegExp(r'\{\s*([A-Za-z_]\w*)\s*[,}]').allMatches(message))
        match.group(1)!,
    }..remove('other');

void main() {
  final english = _messages('en');

  for (final language in ['ja', 'zh']) {
    test('$language says everything English says', () {
      final translated = _messages(language);
      // A missing key would quietly show English in the middle of the app.
      expect(
        english.keys.toSet().difference(translated.keys.toSet()),
        isEmpty,
        reason: 'keys missing from app_$language.arb',
      );
      expect(
        translated.keys.toSet().difference(english.keys.toSet()),
        isEmpty,
        reason: 'keys app_$language.arb has that English dropped',
      );
      for (final key in english.keys) {
        // A dropped placeholder loses the page name or count from a sentence.
        expect(
          _placeholders(translated[key]!),
          _placeholders(english[key]!),
          reason: 'placeholders of $key in app_$language.arb',
        );
      }
    });
  }

  group('the language shown', () {
    Locale shown(String? picked, List<Locale> system) =>
        resolveAppLocale(picked: picked, system: system);

    test('follows the system when nothing is picked', () {
      expect(shown(null, const [Locale('ja', 'JP')]), const Locale('ja'));
      expect(shown(null, const [Locale('en', 'GB')]), const Locale('en'));
    });

    test('is Simplified Chinese for every Chinese system', () {
      expect(
        shown(null, const [
          Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        ]),
        const Locale('zh'),
      );
    });

    test('is the first of the system languages Icarus has', () {
      expect(
        shown(null, const [Locale('fr'), Locale('ja'), Locale('en')]),
        const Locale('ja'),
      );
    });

    test('is English when Icarus has none of them', () {
      expect(shown(null, const [Locale('fr')]), const Locale('en'));
    });

    test('is the one picked in settings, over the system', () {
      expect(shown('zh', const [Locale('ja')]), const Locale('zh'));
    });
  });

  test('every agent, weapon and map has the game\'s own name', () {
    for (final language in ['ja', 'zh']) {
      final l10n = lookupAppLocalizations(Locale(language));
      final agents = AgentData.agents.values.map((agent) => agent.name);
      final weapons = WeaponType.values
          .where((weapon) => weapon != WeaponType.none)
          .map((weapon) => weapon.displayName);
      for (final name in [...agents, ...weapons]) {
        expect(l10n.gameName(name), isNot(name), reason: '$name in $language');
      }
      for (final map in MapValue.values) {
        expect(
          l10n.mapName(map),
          isNot(Maps.displayName(map)),
          reason: '$map in $language',
        );
      }
    }
  });

  group('the picked language', () {
    late Directory tempDir;

    setUpAll(() => registerIcarusAdapters(Hive));

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('icarus-language-');
      Hive.init(tempDir.path);
    });

    tearDown(() async {
      await Hive.close();
      Hive.registerAdapter(AppPreferencesAdapter(), override: true);
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('is the system\'s for preferences saved before languages', () async {
      Hive.registerAdapter(_PreLanguageAdapter(), override: true);
      var box =
          await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
      await box.put(
        MapThemeProfilesProvider.appPreferencesSingletonKey,
        AppPreferences(defaultThemeProfileIdForNewStrategies: 'old-profile'),
      );
      await box.close();
      Hive.registerAdapter(AppPreferencesAdapter(), override: true);

      box = await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
      final read =
          box.get(MapThemeProfilesProvider.appPreferencesSingletonKey)!;

      expect(read.defaultThemeProfileIdForNewStrategies, 'old-profile');
      expect(read.languageCode, isNull);
    });

    test('survives a restart, and can go back to the system\'s', () async {
      await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
      var container = ProviderContainer();
      await container
          .read(appPreferencesProvider.notifier)
          .setLanguageCode('ja');
      await container
          .read(appPreferencesProvider.notifier)
          .flushPendingWrites();
      container.dispose();

      container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(appLocaleProvider), const Locale('ja'));
      expect(container.read(l10nProvider).commonCancel, 'キャンセル');

      await container
          .read(appPreferencesProvider.notifier)
          .setLanguageCode(null);
      expect(container.read(appPreferencesProvider).languageCode, isNull);
    });
  });
}
