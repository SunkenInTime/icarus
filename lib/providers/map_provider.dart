import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/maps.dart';
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
    ref.listen(
      appPreferencesProvider.select(
        (preferences) => (
          preferences.showSpawnBarrier,
          preferences.showUltOrbs,
          preferences.showRegionNames,
        ),
      ),
      (_, __) => state = _withVisibilityFrom(
        ref.read(appPreferencesProvider),
        state,
      ),
    );
    return _withVisibilityFrom(
      ref.read(appPreferencesProvider),
      MapState(currentMap: MapValue.ascent, isAttack: true),
    );
  }

  static MapState _withVisibilityFrom(
    AppPreferences preferences,
    MapState mapState,
  ) =>
      mapState.copyWith(
        showSpawnBarrier: preferences.showSpawnBarrier,
        showUltOrbs: preferences.showUltOrbs,
        showRegionNames: preferences.showRegionNames,
      );

  void updateMap(MapValue map) {
    state = state.copyWith(currentMap: map);
  }

  void fromHive(MapValue map, bool isAttack) {
    state = state.copyWith(currentMap: map, isAttack: isAttack);
  }

  Future<void> updateSpawnBarrier(bool value) {
    return ref.read(appPreferencesProvider.notifier).setShowSpawnBarrier(value);
  }

  Future<void> updateUltOrbs(bool value) {
    return ref.read(appPreferencesProvider.notifier).setShowUltOrbs(value);
  }

  Future<void> updateRegionNames(bool value) {
    return ref.read(appPreferencesProvider.notifier).setShowRegionNames(value);
  }

  void switchSide() {
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
