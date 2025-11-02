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
    MapValue.icebox,
    MapValue.pearl,
    MapValue.corrode,
    MapValue.fracture,
    MapValue.split,
  ];

  static List<MapValue> outofplayMaps = [
    MapValue.sunset,
    MapValue.abyss,
    MapValue.ascent,
    MapValue.lotus,
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
    MapValue.breeze: 1,
    MapValue.lotus: 1.25,
    MapValue.icebox: 1.05,
    MapValue.split: 1.18,
    MapValue.haven: 1.09,
    MapValue.fracture: 1,
    MapValue.pearl: 1,
    MapValue.abyss: 1.167,
    MapValue.sunset: 1.048,
    MapValue.bind: .835,
    MapValue.corrode: .985,
  };
}
