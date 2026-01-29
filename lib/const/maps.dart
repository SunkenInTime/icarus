import 'dart:ui' show Size;

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

  static Map<MapValue, double> mapScale = {
    MapValue.ascent: 1,
    MapValue.breeze: 1.02,
    MapValue.lotus: 1.25,
    MapValue.icebox: 1.05,
    MapValue.split: 1.18,
    MapValue.haven: 1.09,
    MapValue.fracture: 1,
    MapValue.pearl: 1.185,
    MapValue.abyss: 1.167,
    MapValue.sunset: 1.048,
    MapValue.bind: .835,
    MapValue.corrode: .985,
  };

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
}
