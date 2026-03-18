import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';

const String appPreferencesSingletonKey = 'app_preferences';
const String defaultThemeProfileIdFallback = 'immutable-default-map-theme';

class AppPreferences extends HiveObject {
  final String defaultThemeProfileIdForNewStrategies;
  final bool showSpawnBarrier;
  final bool showUltOrbs;
  final bool showRegionNames;
  final double defaultAgentSizeForNewStrategies;
  final double defaultAbilitySizeForNewStrategies;

  AppPreferences({
    this.defaultThemeProfileIdForNewStrategies = defaultThemeProfileIdFallback,
    this.showSpawnBarrier = false,
    this.showUltOrbs = false,
    this.showRegionNames = false,
    this.defaultAgentSizeForNewStrategies = Settings.agentSize,
    this.defaultAbilitySizeForNewStrategies = Settings.abilitySize,
  });

  AppPreferences copyWith({
    String? defaultThemeProfileIdForNewStrategies,
    bool? showSpawnBarrier,
    bool? showUltOrbs,
    bool? showRegionNames,
    double? defaultAgentSizeForNewStrategies,
    double? defaultAbilitySizeForNewStrategies,
  }) {
    return AppPreferences(
      defaultThemeProfileIdForNewStrategies:
          defaultThemeProfileIdForNewStrategies ??
              this.defaultThemeProfileIdForNewStrategies,
      showSpawnBarrier: showSpawnBarrier ?? this.showSpawnBarrier,
      showUltOrbs: showUltOrbs ?? this.showUltOrbs,
      showRegionNames: showRegionNames ?? this.showRegionNames,
      defaultAgentSizeForNewStrategies: defaultAgentSizeForNewStrategies ??
          this.defaultAgentSizeForNewStrategies,
      defaultAbilitySizeForNewStrategies: defaultAbilitySizeForNewStrategies ??
          this.defaultAbilitySizeForNewStrategies,
    );
  }
}

final appPreferencesProvider =
    NotifierProvider<AppPreferencesProvider, AppPreferences>(
        AppPreferencesProvider.new);

class AppPreferencesProvider extends Notifier<AppPreferences> {
  @override
  AppPreferences build() {
    return _readFromHive();
  }

  Future<void> refreshFromHive() async {
    state = _readFromHive();
  }

  Future<void> setShowSpawnBarrier(bool value) async {
    await _persist(state.copyWith(showSpawnBarrier: value));
  }

  Future<void> setShowRegionNames(bool value) async {
    await _persist(state.copyWith(showRegionNames: value));
  }

  Future<void> setShowUltOrbs(bool value) async {
    await _persist(state.copyWith(showUltOrbs: value));
  }

  Future<void> setDefaultAgentSizeForNewStrategies(double value) async {
    await _persist(state.copyWith(defaultAgentSizeForNewStrategies: value));
  }

  Future<void> setDefaultAbilitySizeForNewStrategies(double value) async {
    await _persist(state.copyWith(defaultAbilitySizeForNewStrategies: value));
  }

  Future<void> setDefaultThemeProfileIdForNewStrategies(
      String profileId) async {
    await _persist(
      state.copyWith(defaultThemeProfileIdForNewStrategies: profileId),
    );
  }

  AppPreferences _readFromHive() {
    final box = Hive.box<AppPreferences>(HiveBoxNames.appPreferencesBox);
    final prefs = box.get(appPreferencesSingletonKey);
    if (prefs != null) {
      return prefs;
    }

    final defaults = AppPreferences();
    unawaited(box.put(appPreferencesSingletonKey, defaults));
    return defaults;
  }

  Future<void> _persist(AppPreferences next) async {
    state = next;
    await Hive.box<AppPreferences>(HiveBoxNames.appPreferencesBox).put(
      appPreferencesSingletonKey,
      next,
    );
  }
}
