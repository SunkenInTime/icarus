import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/theme/ui_theme_models.dart';
import 'package:icarus/theme/ui_theme_tokens.dart';
import 'package:uuid/uuid.dart';

final uiThemeProvider = NotifierProvider<UiThemeProvider, UiThemeState>(
  UiThemeProvider.new,
);

final effectiveUiThemeProvider = Provider<UiThemeResolvedData>((ref) {
  final state = ref.watch(uiThemeProvider);
  final active = state.activeProfile;

  final colors = UiThemeTokenRegistry.defaultColorMap();
  colors.addAll(active.colorValues);

  final shadows = UiThemeTokenRegistry.defaultShadowMap();
  for (final entry in active.shadowValues.entries) {
    shadows[entry.key] = List<UiShadowLayerDefinition>.from(entry.value);
  }

  return UiThemeResolvedData(colors: colors, shadows: shadows);
});

class UiThemeProvider extends Notifier<UiThemeState> {
  static const String builtInProfileId = 'builtin_tactical_violet';
  static const String builtInDesignerContextProfileId =
      'builtin_designer_context';
  static const String activeProfileKey = 'active_profile_id';

  static UiThemeProfile get builtInProfile {
    return UiThemeProfile(
      id: builtInProfileId,
      name: 'Tactical Violet',
      colorValues: UiThemeTokenRegistry.defaultColorMap(),
      shadowValues: UiThemeTokenRegistry.defaultShadowMap(),
      isBuiltIn: true,
    );
  }

  static UiThemeProfile get builtInDesignerContextProfile {
    final colors = UiThemeTokenRegistry.defaultColorMap()
      ..addAll({
        UiThemeTokenIds.shadBackground: 0xFFFFFFFF,
        UiThemeTokenIds.shadForeground: 0xFF09090B,
        UiThemeTokenIds.shadCard: 0xFFF4F4F5,
        UiThemeTokenIds.shadCardForeground: 0xFF18181B,
        UiThemeTokenIds.shadPopover: 0xFFFFFFFF,
        UiThemeTokenIds.shadPopoverForeground: 0xFF18181B,
        UiThemeTokenIds.shadSecondary: 0xFFE4E4E7,
        UiThemeTokenIds.shadMuted: 0xFFF4F4F5,
        UiThemeTokenIds.shadMutedForeground: 0xFF71717A,
        UiThemeTokenIds.shadPrimary: 0xFF7C3AED,
        UiThemeTokenIds.shadPrimaryForeground: 0xFFF9FAFB,
        UiThemeTokenIds.shadRing: 0xFF7C3AED,
        UiThemeTokenIds.shadSelection: 0xFFEDE9FE,
        UiThemeTokenIds.shadDestructive: 0xFFEF4444,
        UiThemeTokenIds.shadDestructiveForeground: 0xFFFAFAFA,
        UiThemeTokenIds.shadBorder: 0xFFD4D4D8,
        UiThemeTokenIds.shadInput: 0xFFD4D4D8,
        UiThemeTokenIds.sidebarSurface: 0xFFEDE9FE,
        UiThemeTokenIds.sidebarHighlight: 0xFFD4D4D8,
        UiThemeTokenIds.abilityBg: 0xFFE4E4E7,
        UiThemeTokenIds.enemyBg: 0xFFFDE8E8,
        UiThemeTokenIds.allyBg: 0xFFDCFCE7,
        UiThemeTokenIds.enemyOutline: 0xFFFCA5A5,
        UiThemeTokenIds.allyOutline: 0xFF6EE7B7,
      });

    return UiThemeProfile(
      id: builtInDesignerContextProfileId,
      name: 'Designer Context',
      colorValues: colors,
      shadowValues: UiThemeTokenRegistry.defaultShadowMap(),
      isBuiltIn: true,
    );
  }

  static List<UiThemeProfile> get builtInProfiles => [
        builtInProfile,
        builtInDesignerContextProfile,
      ];

  static UiThemeProfile fallbackBuiltInProfile() => builtInProfiles.first;

  @override
  UiThemeState build() {
    final profilesBox = Hive.box<String>(HiveBoxNames.uiThemeProfilesBox);
    final prefsBox = Hive.box<String>(HiveBoxNames.uiThemePrefsBox);

    final profiles = <UiThemeProfile>[];
    for (final raw in profilesBox.values) {
      try {
        profiles.add(UiThemeProfile.decode(raw));
      } catch (_) {}
    }

    for (final builtIn in builtInProfiles) {
      if (!profiles.any((profile) => profile.id == builtIn.id)) {
        profiles.add(builtIn);
      }
    }

    profiles.sort((a, b) {
      final aBuiltInIndex = builtInProfiles.indexWhere((p) => p.id == a.id);
      final bBuiltInIndex = builtInProfiles.indexWhere((p) => p.id == b.id);
      final aIsBuiltIn = aBuiltInIndex != -1;
      final bIsBuiltIn = bBuiltInIndex != -1;
      if (aIsBuiltIn && bIsBuiltIn) {
        return aBuiltInIndex.compareTo(bBuiltInIndex);
      }
      if (aIsBuiltIn && !bIsBuiltIn) return -1;
      if (!aIsBuiltIn && bIsBuiltIn) return 1;
      return a.createdAt.compareTo(b.createdAt);
    });

    final defaultBuiltInId = fallbackBuiltInProfile().id;
    final preferredId = prefsBox.get(activeProfileKey) ?? defaultBuiltInId;
    final activeId = profiles.any((profile) => profile.id == preferredId)
        ? preferredId
        : defaultBuiltInId;

    return UiThemeState(
      profiles: profiles,
      activeProfileId: activeId,
    );
  }

  static Future<void> bootstrap() async {
    final profilesBox = Hive.box<String>(HiveBoxNames.uiThemeProfilesBox);
    final prefsBox = Hive.box<String>(HiveBoxNames.uiThemePrefsBox);

    for (final builtIn in builtInProfiles) {
      final existing = profilesBox.get(builtIn.id);
      if (existing == null) {
        await profilesBox.put(builtIn.id, builtIn.encode());
        continue;
      }

      try {
        final decoded = UiThemeProfile.decode(existing);
        final repaired = decoded.copyWith(
          name: builtIn.name,
          isBuiltIn: true,
          colorValues: {
            ...builtIn.colorValues,
            ...decoded.colorValues,
          },
          shadowValues: {
            ...builtIn.shadowValues,
            ...decoded.shadowValues,
          },
        );
        await profilesBox.put(builtIn.id, repaired.encode());
      } catch (_) {
        await profilesBox.put(builtIn.id, builtIn.encode());
      }
    }

    final defaultBuiltInId = fallbackBuiltInProfile().id;
    final activeId = prefsBox.get(activeProfileKey);
    if (activeId == null || !profilesBox.containsKey(activeId)) {
      await prefsBox.put(activeProfileKey, defaultBuiltInId);
    }
  }

  Future<void> refresh() async {
    state = build();
  }

  Future<void> setActiveProfile(String profileId) async {
    if (!state.profiles.any((profile) => profile.id == profileId)) {
      return;
    }
    await Hive.box<String>(HiveBoxNames.uiThemePrefsBox)
        .put(activeProfileKey, profileId);
    await refresh();
  }

  Future<void> createProfileFromActive({required String name}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;

    final effective = _resolveEffectiveData(state.activeProfile);
    final profile = UiThemeProfile(
      id: const Uuid().v4(),
      name: trimmed,
      colorValues: Map<String, int>.from(effective.colors),
      shadowValues: {
        for (final entry in effective.shadows.entries)
          entry.key: List<UiShadowLayerDefinition>.from(entry.value),
      },
      isBuiltIn: false,
    );

    await Hive.box<String>(HiveBoxNames.uiThemeProfilesBox)
        .put(profile.id, profile.encode());
    await Hive.box<String>(HiveBoxNames.uiThemePrefsBox)
        .put(activeProfileKey, profile.id);
    await refresh();
  }

  Future<void> renameProfile({
    required String profileId,
    required String newName,
  }) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;

    final profile = state.profiles.firstWhere(
      (item) => item.id == profileId,
      orElse: fallbackBuiltInProfile,
    );
    if (profile.isBuiltIn) return;

    final updated = profile.copyWith(name: trimmed);
    await Hive.box<String>(HiveBoxNames.uiThemeProfilesBox)
        .put(profileId, updated.encode());
    await refresh();
  }

  Future<void> deleteProfile(String profileId) async {
    final profile = state.profiles.firstWhere(
      (item) => item.id == profileId,
      orElse: fallbackBuiltInProfile,
    );
    if (profile.isBuiltIn) return;

    await Hive.box<String>(HiveBoxNames.uiThemeProfilesBox).delete(profileId);

    if (state.activeProfileId == profileId) {
      await Hive.box<String>(HiveBoxNames.uiThemePrefsBox)
          .put(activeProfileKey, fallbackBuiltInProfile().id);
    }

    await refresh();
  }

  Future<void> updateColorToken({
    required String tokenId,
    required int colorValue,
  }) async {
    final active = state.activeProfile;
    final colorValues = Map<String, int>.from(active.colorValues)
      ..[tokenId] = colorValue;
    final updated = active.copyWith(colorValues: colorValues);
    await Hive.box<String>(HiveBoxNames.uiThemeProfilesBox)
        .put(updated.id, updated.encode());
    state = state.copyWith(
      profiles: [
        for (final profile in state.profiles)
          if (profile.id == updated.id) updated else profile,
      ],
    );
  }

  Future<void> resetColorToken(String tokenId) async {
    final active = state.activeProfile;
    final defaultMap = UiThemeTokenRegistry.defaultColorMap();
    final colorValues = Map<String, int>.from(active.colorValues)
      ..[tokenId] =
          defaultMap[tokenId] ?? active.colorValues[tokenId] ?? 0xFF000000;
    final updated = active.copyWith(colorValues: colorValues);
    await Hive.box<String>(HiveBoxNames.uiThemeProfilesBox)
        .put(updated.id, updated.encode());
    state = state.copyWith(
      profiles: [
        for (final profile in state.profiles)
          if (profile.id == updated.id) updated else profile,
      ],
    );
  }

  Future<void> updateShadowToken({
    required String tokenId,
    required List<UiShadowLayerDefinition> layers,
  }) async {
    final active = state.activeProfile;
    final shadowValues =
        Map<String, List<UiShadowLayerDefinition>>.from(active.shadowValues)
          ..[tokenId] = List<UiShadowLayerDefinition>.from(layers);
    final updated = active.copyWith(shadowValues: shadowValues);
    await Hive.box<String>(HiveBoxNames.uiThemeProfilesBox)
        .put(updated.id, updated.encode());
    state = state.copyWith(
      profiles: [
        for (final profile in state.profiles)
          if (profile.id == updated.id) updated else profile,
      ],
    );
  }

  Future<void> resetShadowToken(String tokenId) async {
    final active = state.activeProfile;
    final defaults = UiThemeTokenRegistry.defaultShadowMap();
    final shadowValues =
        Map<String, List<UiShadowLayerDefinition>>.from(active.shadowValues)
          ..[tokenId] = List<UiShadowLayerDefinition>.from(
              defaults[tokenId] ?? const <UiShadowLayerDefinition>[]);
    final updated = active.copyWith(shadowValues: shadowValues);
    await Hive.box<String>(HiveBoxNames.uiThemeProfilesBox)
        .put(updated.id, updated.encode());
    state = state.copyWith(
      profiles: [
        for (final profile in state.profiles)
          if (profile.id == updated.id) updated else profile,
      ],
    );
  }

  UiThemeResolvedData _resolveEffectiveData(UiThemeProfile profile) {
    final colors = UiThemeTokenRegistry.defaultColorMap();
    colors.addAll(profile.colorValues);

    final shadows = UiThemeTokenRegistry.defaultShadowMap();
    for (final entry in profile.shadowValues.entries) {
      shadows[entry.key] = List<UiShadowLayerDefinition>.from(entry.value);
    }

    return UiThemeResolvedData(colors: colors, shadows: shadows);
  }

  String exportActiveThemeJson({
    required Map<String, String> mapColors,
  }) {
    final profile = state.activeProfile;
    final effective = _resolveEffectiveData(profile);

    final payload = {
      'schemaVersion': 1,
      'profile': {
        'id': profile.id,
        'name': profile.name,
        'isBuiltIn': profile.isBuiltIn,
      },
      'uiColors': effective.exportColorHexMap(),
      'uiShadows': effective.exportShadowMap(),
      'mapColors': mapColors,
      'exportedAt': DateTime.now().toIso8601String(),
    };

    return const JsonEncoder.withIndent('  ').convert(payload);
  }
}
