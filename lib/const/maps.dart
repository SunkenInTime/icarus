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
  summit,
}

class Maps {
  static List<MapValue> availableMaps = [
    MapValue.ascent,
    MapValue.breeze,
    MapValue.haven,
    MapValue.lotus,
    MapValue.split,
    MapValue.sunset,
    MapValue.summit,
  ];

  static List<MapValue> outofplayMaps = [
    MapValue.abyss,
    MapValue.bind,
    MapValue.corrode,
    MapValue.fracture,
    MapValue.icebox,
    MapValue.pearl,
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
    MapValue.summit: 'summit',
  };

  static Map<MapValue, double> mapScale = {
    MapValue.ascent: 1.0,
    MapValue.bind: 0.835, // modified
    MapValue.breeze: 1.01, //modified
    MapValue.lotus: 1.24, //modified
    MapValue.icebox: 1.03, //modiefied
    MapValue.sunset: 0.9502102049421427,
    MapValue.split: 1.1920129279062075, //modified
    MapValue.haven: 1.06, //modified
    MapValue.fracture: 1.21, //modified
    MapValue.abyss: 1.138, //modified
    MapValue.pearl: 1.11, //modified
    MapValue.corrode: 0.985,
    MapValue.summit: 1.03,
  };
}
