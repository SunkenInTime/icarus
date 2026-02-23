import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter/material.dart';

enum MapValue {
  ascent,
  breeze,
  lotus,
  icebox,
  sunset,
  split,
  haven,
  fracture,
  abyss,
  pearl,
  bind,
  corrode,
}

class Maps {
  // Playable dimensions (meters) derived from Valorant map bounds after removing
  // display-icon padding from the padded minimap world extent.
  static const Map<MapValue, Size> mapPlayableMeters = {
    MapValue.ascent: Size(12418.91682031634, 13326.491033008337),
    MapValue.bind: Size(11512.621459595475, 12175.77133315273),
    MapValue.breeze: Size(13395.904430787905, 13222.156668189),
    MapValue.lotus: Size(12179.83511197221, 11002.003263176117),
    MapValue.icebox: Size(11495.558837879202, 13083.067808295538),
    MapValue.sunset: Size(11881.031268613191, 12577.223294152906),
    MapValue.split: Size(15738.349327986287, 14941.778019870651),
    MapValue.haven: Size(11186.97301971374, 12517.093011464156),
    MapValue.fracture: Size(11583.889845070918, 11148.643072224917),
    MapValue.abyss: Size(12019.131598227425, 11663.010340975046),
    MapValue.pearl: Size(12720.700077897336, 11959.810989473342),
    MapValue.corrode: Size(12031.771816700097, 13671.313297776283),
  };

  static List<MapValue> availableMaps = [
    MapValue.bind,
    MapValue.haven,
    MapValue.pearl,
    MapValue.corrode,
    MapValue.split,
    MapValue.breeze,
    MapValue.abyss,
  ];

  static List<MapValue> outofplayMaps = [
    MapValue.sunset,
    MapValue.ascent,
    MapValue.lotus,
    MapValue.icebox,
    MapValue.fracture,
  ];

  static Map<MapValue, String> mapNames = {
    MapValue.ascent: 'ascent',
    MapValue.breeze: 'breeze',
    MapValue.lotus: 'lotus',
    MapValue.icebox: 'icebox',
    MapValue.sunset: 'sunset',
    MapValue.split: 'split',
    MapValue.haven: 'haven',
    MapValue.fracture: 'fracture',
    MapValue.abyss: 'abyss',
    MapValue.pearl: 'pearl',
    MapValue.bind: 'bind',
    MapValue.corrode: 'corrode',
  };

  // Per-map scalar for ability rendering using Ascent as baseline (1.0).
  // Formula: sqrt((playableWidth * playableHeight) / ascentPlayableArea)
  static final Map<MapValue, double> mapScale = buildMapScaleFromPlayableArea();

  static Map<MapValue, double> buildMapScaleFromPlayableArea({
    MapValue baselineMap = MapValue.ascent,
  }) {
    final ascent = mapPlayableMeters[baselineMap]!;
    final ascentArea = ascent.width * ascent.height;
    return {
      for (final entry in mapPlayableMeters.entries)
        entry.key: math.sqrt((entry.value.width * entry.value.height) / ascentArea),
    };
  }

  static const Map<MapValue, Size> mapViewBox = {
    MapValue.ascent: Size(411, 474),
    MapValue.breeze: Size(448, 474),
    MapValue.lotus: Size(494, 473),
    MapValue.icebox: Size(387, 473),
    MapValue.sunset: Size(416, 473),
    MapValue.split: Size(467, 473),
    MapValue.haven: Size(395, 474),
    MapValue.fracture: Size(460, 473),
    MapValue.abyss: Size(452, 474),
    MapValue.pearl: Size(469, 473),
    MapValue.bind: Size(416, 474),
    MapValue.corrode: Size(387, 473),
  };

  static const Map<MapValue, Size> defenseMapViewBox = {
    MapValue.ascent: Size(411, 474),
    MapValue.breeze: Size(448, 474),
    MapValue.lotus: Size(494, 473),
    MapValue.icebox: Size(387, 473),
    MapValue.sunset: Size(416, 473),
    MapValue.split: Size(467, 473),
    MapValue.haven: Size(395, 474),
    MapValue.fracture: Size(460, 473),
    MapValue.abyss: Size(452, 474),
    MapValue.pearl: Size(469, 473),
    MapValue.bind: Size(416, 474),
    MapValue.corrode: Size(387, 473),
  };

  static const Map<MapValue, Size> spawnWallViewBox = {
    MapValue.ascent: Size(410, 474),
  };

  static const Map<MapValue, EdgeInsets> valorantDisplayIconPaddingVb = {
    MapValue.abyss: EdgeInsets.fromLTRB(6.82243, 13.64486, 5.457944, 14.099688),
    MapValue.ascent:
        EdgeInsets.fromLTRB(40.111579, 18.903158, 21.669474, 15.214737),
    MapValue.bind: EdgeInsets.fromLTRB(40.92824, 5.653072, 6.33144, 19.446567),
    MapValue.breeze:
        EdgeInsets.fromLTRB(14.878981, 14.878981, 14.878981, 23.248408),
    MapValue.corrode:
        EdgeInsets.fromLTRB(36.248848, 14.320533, 36.248848, 6.936508),
    MapValue.fracture:
        EdgeInsets.fromLTRB(10.912599, 34.22588, 38.194098, 36.706016),
    MapValue.haven:
        EdgeInsets.fromLTRB(36.63356, 16.027182, 39.152117, 14.882384),
    MapValue.icebox:
        EdgeInsets.fromLTRB(44.838021, 28.678125, 35.733854, 0.455208),
    MapValue.lotus:
        EdgeInsets.fromLTRB(30.685893, 66.303448, 38.631348, 57.810031),
    MapValue.pearl: EdgeInsets.fromLTRB(1.38, 16.56, 2.3, 17.48),
    MapValue.split:
        EdgeInsets.fromLTRB(13.442394, 25.907159, 22.485459, 37.638702),
    MapValue.sunset:
        EdgeInsets.fromLTRB(20.041874, 3.921236, 12.852941, 5.228315),
  };
}
