import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';

final mapProvider = NotifierProvider<MapProvider, MapState>(MapProvider.new);

class MapState {
  final MapValue currentMap;
  final bool isAttack;
  final bool showSpawnBarrier;
  final bool showUltOrbs;
  final bool showRegionNames;

  MapState({
    required this.currentMap,
    required this.isAttack,
    this.showSpawnBarrier = false,
    this.showUltOrbs = false,
    this.showRegionNames = false,
  });

  MapState copyWith({
    MapValue? currentMap,
    bool? isAttack,
    bool? showSpawnBarrier,
    bool? showUltOrbs,
    bool? showRegionNames,
  }) {
    return MapState(
      currentMap: currentMap ?? this.currentMap,
      isAttack: isAttack ?? this.isAttack,
      showSpawnBarrier: showSpawnBarrier ?? this.showSpawnBarrier,
      showUltOrbs: showUltOrbs ?? this.showUltOrbs,
      showRegionNames: showRegionNames ?? this.showRegionNames,
    );
  }
}

class MapProvider extends Notifier<MapState> {
  @override
  MapState build() {
    final preferences = ref.read(appPreferencesProvider);
    return MapState(
      currentMap: MapValue.ascent,
      isAttack: true,
      showSpawnBarrier: preferences.showSpawnBarrier,
      showUltOrbs: preferences.showUltOrbs,
      showRegionNames: preferences.showRegionNames,
    );
  }

  void updateMap(MapValue map) => state = state.copyWith(currentMap: map);

  void fromHive(MapValue map, bool isAttack) {
    state = state.copyWith(currentMap: map, isAttack: isAttack);
  }

  void syncVisibilityFromPreferences(AppPreferences preferences) {
    state = state.copyWith(
      showSpawnBarrier: preferences.showSpawnBarrier,
      showUltOrbs: preferences.showUltOrbs,
      showRegionNames: preferences.showRegionNames,
    );
  }

  Future<void> updateSpawnBarrier(bool value) async {
    state = state.copyWith(showSpawnBarrier: value);
    await ref.read(appPreferencesProvider.notifier).setShowSpawnBarrier(value);
  }

  Future<void> updateUltOrbs(bool value) async {
    state = state.copyWith(showUltOrbs: value);
    await ref.read(appPreferencesProvider.notifier).setShowUltOrbs(value);
  }

  Future<void> updateRegionNames(bool value) async {
    state = state.copyWith(showRegionNames: value);
    await ref.read(appPreferencesProvider.notifier).setShowRegionNames(value);
  }

  void switchSide() {
    // Flip all placed agents to mirror positions before toggling the side
    ref.read(agentProvider.notifier).switchSides();
    ref.read(abilityProvider.notifier).switchSides();
    ref.read(utilityProvider.notifier).switchSides();
    ref.read(lineUpProvider.notifier).switchSides();
    ref.read(textProvider.notifier).switchSides();
    ref.read(placedImageProvider.notifier).switchSides();
    state = state.copyWith(isAttack: !state.isAttack);
  }

  void setAttack(bool isAttack) {
    state = state.copyWith(isAttack: isAttack);
  }

  String toJson() {
    return '"${Maps.mapNames[state.currentMap]}"';
  }

  static MapValue fromJson(String json) {
    final mapName = jsonDecode(json);

    final mapValue =
        Maps.mapNames.entries.firstWhere((entry) => entry.value == mapName).key;

    return mapValue;
  }
}
