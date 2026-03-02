import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:uuid/uuid.dart';

class MapThemePalette extends HiveObject {
  final int baseColorValue;
  final int detailColorValue;
  final int highlightColorValue;

  MapThemePalette({
    required this.baseColorValue,
    required this.detailColorValue,
    required this.highlightColorValue,
  });

  Color get baseColor => Color(baseColorValue);
  Color get detailColor => Color(detailColorValue);
  Color get highlightColor => Color(highlightColorValue);

  MapThemePalette copyWith({
    int? baseColorValue,
    int? detailColorValue,
    int? highlightColorValue,
  }) {
    return MapThemePalette(
      baseColorValue: baseColorValue ?? this.baseColorValue,
      detailColorValue: detailColorValue ?? this.detailColorValue,
      highlightColorValue: highlightColorValue ?? this.highlightColorValue,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'base': _toHex(baseColorValue),
      'detail': _toHex(detailColorValue),
      'highlight': _toHex(highlightColorValue),
    };
  }

  factory MapThemePalette.fromJson(Map<String, dynamic> json) {
    return MapThemePalette(
      baseColorValue: _fromHex(json['base']?.toString()),
      detailColorValue: _fromHex(json['detail']?.toString()),
      highlightColorValue: _fromHex(json['highlight']?.toString()),
    );
  }

  static String _toHex(int colorValue) {
    final rgb = colorValue & 0x00FFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  static int _fromHex(String? hex) {
    if (hex == null || hex.isEmpty) {
      return 0xFF000000;
    }
    final cleaned = hex.startsWith('#') ? hex.substring(1) : hex;
    final normalized = cleaned.length == 6 ? 'FF$cleaned' : cleaned;
    return int.parse(normalized, radix: 16);
  }

  @override
  bool operator ==(Object other) {
    return other is MapThemePalette &&
        other.baseColorValue == baseColorValue &&
        other.detailColorValue == detailColorValue &&
        other.highlightColorValue == highlightColorValue;
  }

  @override
  int get hashCode =>
      Object.hash(baseColorValue, detailColorValue, highlightColorValue);
}

class MapThemeProfile extends HiveObject {
  final String id;
  final String name;
  final MapThemePalette palette;
  final bool isBuiltIn;
  final DateTime createdAt;

  MapThemeProfile({
    required this.id,
    required this.name,
    required this.palette,
    required this.isBuiltIn,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  MapThemeProfile copyWith({
    String? id,
    String? name,
    MapThemePalette? palette,
    bool? isBuiltIn,
    DateTime? createdAt,
  }) {
    return MapThemeProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      palette: palette ?? this.palette,
      isBuiltIn: isBuiltIn ?? this.isBuiltIn,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

class AppPreferences extends HiveObject {
  final String defaultThemeProfileIdForNewStrategies;

  AppPreferences({
    required this.defaultThemeProfileIdForNewStrategies,
  });

  AppPreferences copyWith({
    String? defaultThemeProfileIdForNewStrategies,
  }) {
    return AppPreferences(
      defaultThemeProfileIdForNewStrategies:
          defaultThemeProfileIdForNewStrategies ??
              this.defaultThemeProfileIdForNewStrategies,
    );
  }
}

class StrategyThemeState {
  final String? profileId;
  final MapThemePalette? overridePalette;

  const StrategyThemeState({
    this.profileId,
    this.overridePalette,
  });

  StrategyThemeState copyWith({
    String? profileId,
    bool clearProfileId = false,
    MapThemePalette? overridePalette,
    bool clearOverride = false,
  }) {
    return StrategyThemeState(
      profileId: clearProfileId ? null : (profileId ?? this.profileId),
      overridePalette:
          clearOverride ? null : (overridePalette ?? this.overridePalette),
    );
  }
}

class MapThemeProfilesState {
  final List<MapThemeProfile> profiles;
  final String defaultProfileIdForNewStrategies;

  const MapThemeProfilesState({
    required this.profiles,
    required this.defaultProfileIdForNewStrategies,
  });

  MapThemeProfilesState copyWith({
    List<MapThemeProfile>? profiles,
    String? defaultProfileIdForNewStrategies,
  }) {
    return MapThemeProfilesState(
      profiles: profiles ?? this.profiles,
      defaultProfileIdForNewStrategies: defaultProfileIdForNewStrategies ??
          this.defaultProfileIdForNewStrategies,
    );
  }
}

final mapThemeProfilesProvider =
    NotifierProvider<MapThemeProfilesProvider, MapThemeProfilesState>(
        MapThemeProfilesProvider.new);

final strategyThemeProvider =
    NotifierProvider<StrategyThemeProvider, StrategyThemeState>(
        StrategyThemeProvider.new);

final effectiveMapThemePaletteProvider = Provider<MapThemePalette>((ref) {
  final profilesState = ref.watch(mapThemeProfilesProvider);
  final strategyTheme = ref.watch(strategyThemeProvider);

  if (strategyTheme.overridePalette != null) {
    return strategyTheme.overridePalette!;
  }

  final profileId = strategyTheme.profileId ??
      MapThemeProfilesProvider.immutableDefaultProfileId;
  final selected = profilesState.profiles.firstWhere(
    (profile) => profile.id == profileId,
    orElse: () => profilesState.profiles.firstWhere(
      (profile) =>
          profile.id == MapThemeProfilesProvider.immutableDefaultProfileId,
      orElse: () => MapThemeProfilesProvider.immutableDefaultProfile,
    ),
  );
  return selected.palette;
});

class MapThemeProfilesProvider extends Notifier<MapThemeProfilesState> {
  static const String immutableDefaultProfileId = 'immutable-default-map-theme';
  static const String immutableValorantProfileId =
      'immutable-valorant-map-theme';
  static const String appPreferencesSingletonKey = 'app_preferences';
  static const int customProfilesSoftCap = 10;

  static final MapThemePalette immutableDefaultPalette = MapThemePalette(
    baseColorValue: 0xFF271406,
    detailColorValue: 0xFFB27C40,
    highlightColorValue: 0xFFF08234,
  );

  static final MapThemeProfile immutableDefaultProfile = MapThemeProfile(
    id: immutableDefaultProfileId,
    name: 'Default',
    palette: immutableDefaultPalette,
    isBuiltIn: true,
  );

  static final MapThemePalette immutableValorantPalette = MapThemePalette(
    baseColorValue: 0xFF767676,
    detailColorValue: 0xFFFFFFFF,
    highlightColorValue: 0xFFF6F23E,
  );

  static final MapThemeProfile immutableValorantProfile = MapThemeProfile(
    id: immutableValorantProfileId,
    name: 'Valorant',
    palette: immutableValorantPalette,
    isBuiltIn: true,
  );

  static final List<MapThemeProfile> immutableBuiltInProfiles = [
    immutableDefaultProfile,
    immutableValorantProfile,
  ];

  @override
  MapThemeProfilesState build() {
    final profileBox =
        Hive.box<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    final appPrefsBox =
        Hive.box<AppPreferences>(HiveBoxNames.appPreferencesBox);

    final allProfiles = profileBox.values.toList(growable: false);
    final profilesById = {
      for (final profile in allProfiles) profile.id: profile,
    };
    final builtInProfiles = immutableBuiltInProfiles
        .map((builtIn) => profilesById[builtIn.id] ?? builtIn)
        .toList(growable: false);
    final builtInProfileIds = builtInProfiles.map((profile) => profile.id).toSet();
    final customProfiles = allProfiles
        .where((profile) => !builtInProfileIds.contains(profile.id))
        .toList(growable: false);
    final sortedProfiles = [
      ...builtInProfiles,
      ...customProfiles,
    ];

    final appPrefs = appPrefsBox.get(appPreferencesSingletonKey);
    final defaultProfileId = appPrefs?.defaultThemeProfileIdForNewStrategies ??
        immutableDefaultProfileId;

    final resolvedDefault =
        sortedProfiles.any((profile) => profile.id == defaultProfileId)
            ? defaultProfileId
            : immutableDefaultProfileId;

    return MapThemeProfilesState(
      profiles: sortedProfiles,
      defaultProfileIdForNewStrategies: resolvedDefault,
    );
  }

  bool get customProfilesAtCap =>
      state.profiles.where((profile) => !profile.isBuiltIn).length >=
      customProfilesSoftCap;

  Future<void> refreshFromHive() async {
    state = build();
  }

  Future<bool> createProfile({
    required String name,
    required MapThemePalette palette,
  }) async {
    if (customProfilesAtCap) {
      return false;
    }
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      return false;
    }
    final profile = MapThemeProfile(
      id: const Uuid().v4(),
      name: trimmedName,
      palette: palette,
      isBuiltIn: false,
    );
    await Hive.box<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox)
        .put(profile.id, profile);
    await refreshFromHive();
    return true;
  }

  Future<void> renameProfile({
    required String profileId,
    required String newName,
  }) async {
    final profile = _findProfile(profileId);
    if (profile == null || profile.isBuiltIn) {
      return;
    }
    final trimmed = newName.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final updated = profile.copyWith(name: trimmed);
    await Hive.box<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox)
        .put(updated.id, updated);
    await refreshFromHive();
  }

  Future<void> updateProfilePalette({
    required String profileId,
    required MapThemePalette palette,
  }) async {
    final profile = _findProfile(profileId);
    if (profile == null || profile.isBuiltIn) {
      return;
    }
    final updated = profile.copyWith(palette: palette);
    await Hive.box<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox)
        .put(updated.id, updated);
    await refreshFromHive();
  }

  Future<void> deleteProfile(String profileId) async {
    final profile = _findProfile(profileId);
    if (profile == null || profile.isBuiltIn) {
      return;
    }
    await Hive.box<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox)
        .delete(profileId);

    if (state.defaultProfileIdForNewStrategies == profileId) {
      await setDefaultProfileForNewStrategies(immutableDefaultProfileId);
    } else {
      await refreshFromHive();
    }
  }

  Future<void> setDefaultProfileForNewStrategies(String profileId) async {
    final profileExists = state.profiles.any((p) => p.id == profileId);
    final resolvedProfileId =
        profileExists ? profileId : immutableDefaultProfileId;

    await Hive.box<AppPreferences>(HiveBoxNames.appPreferencesBox).put(
      appPreferencesSingletonKey,
      AppPreferences(
        defaultThemeProfileIdForNewStrategies: resolvedProfileId,
      ),
    );
    await refreshFromHive();
  }

  MapThemeProfile? _findProfile(String profileId) {
    return state.profiles
            .firstWhere(
              (profile) => profile.id == profileId,
              orElse: () => MapThemeProfile(
                id: '',
                name: '',
                palette: immutableDefaultPalette,
                isBuiltIn: true,
              ),
            )
            .id
            .isEmpty
        ? null
        : state.profiles.firstWhere((profile) => profile.id == profileId);
  }

  static Future<void> bootstrap() async {
    final profileBox =
        Hive.box<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    final appPrefsBox =
        Hive.box<AppPreferences>(HiveBoxNames.appPreferencesBox);

    for (final builtIn in immutableBuiltInProfiles) {
      final existing = profileBox.get(builtIn.id);
      if (existing == null) {
        await profileBox.put(builtIn.id, builtIn);
        continue;
      }
      if (_shouldRepairBuiltIn(existing: existing, expected: builtIn)) {
        await profileBox.put(
          builtIn.id,
          builtIn.copyWith(
            createdAt: existing.createdAt,
          ),
        );
      }
    }

    final prefs = appPrefsBox.get(appPreferencesSingletonKey);
    if (prefs == null ||
        profileBox.get(prefs.defaultThemeProfileIdForNewStrategies) == null) {
      await appPrefsBox.put(
        appPreferencesSingletonKey,
        AppPreferences(
          defaultThemeProfileIdForNewStrategies: immutableDefaultProfileId,
        ),
      );
    }
  }

  static int nextGeneratedProfileNumber(List<MapThemeProfile> profiles) {
    var highest = 0;
    final pattern = RegExp(r'^Profile (\d+)$');
    for (final profile in profiles) {
      final match = pattern.firstMatch(profile.name);
      if (match == null) {
        continue;
      }
      final value = int.tryParse(match.group(1) ?? '');
      if (value != null) {
        highest = max(highest, value);
      }
    }
    return highest + 1;
  }

  static bool _shouldRepairBuiltIn({
    required MapThemeProfile existing,
    required MapThemeProfile expected,
  }) {
    return !existing.isBuiltIn ||
        existing.name != expected.name ||
        existing.palette != expected.palette;
  }
}

class StrategyThemeProvider extends Notifier<StrategyThemeState> {
  @override
  StrategyThemeState build() {
    return const StrategyThemeState();
  }

  void fromStrategy({
    String? profileId,
    MapThemePalette? overridePalette,
  }) {
    state = StrategyThemeState(
      profileId: profileId,
      overridePalette: overridePalette,
    );
  }

  void setProfile(String profileId) {
    state = state.copyWith(
      profileId: profileId,
      clearOverride: true,
    );
  }

  void setOverride(MapThemePalette palette) {
    state = state.copyWith(
      overridePalette: palette,
      clearProfileId: true,
    );
  }

  void clearOverride() {
    state = state.copyWith(clearOverride: true);
  }
}
