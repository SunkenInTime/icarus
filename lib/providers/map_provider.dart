import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/maps.dart';

final mapProvider = NotifierProvider<MapProvider, MapState>(MapProvider.new);

class MapState {
  final MapValue currentMap;
  final bool isAttack;
  final bool showSpawnBarrier;

  MapState(
      {required this.currentMap,
      required this.isAttack,
      this.showSpawnBarrier = false});

  MapState copyWith(
      {MapValue? currentMap, bool? isAttack, bool? showSpawnBarrier}) {
    return MapState(
      currentMap: currentMap ?? this.currentMap,
      isAttack: isAttack ?? this.isAttack,
      showSpawnBarrier: showSpawnBarrier ?? this.showSpawnBarrier,
    );
  }
}

class MapProvider extends Notifier<MapState> {
  @override
  MapState build() {
    return MapState(currentMap: MapValue.ascent, isAttack: true);
  }

  double get mapScale => Maps.mapScale[state.currentMap]!;

  void updateMap(MapValue map) => state = state.copyWith(currentMap: map);

  void fromHive(MapValue map, bool isAttack) {
    state = state.copyWith(currentMap: map, isAttack: isAttack);
  }

  void updateSpawnBarrier(bool value) {
    state = state.copyWith(showSpawnBarrier: value);
  }

  void switchSide() {
    state = state.copyWith(isAttack: !state.isAttack);
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
