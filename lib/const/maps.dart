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
  summit,
}

class VisionGeometryAlignment {
  const VisionGeometryAlignment({
    this.scaleX = 1,
    this.scaleY = 1,
    this.offset = Offset.zero,
  });

  final double scaleX;
  final double scaleY;
  final Offset offset;
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
    MapValue.sunset: 1.06,
    MapValue.split: 1.1920129279062075, //modified
    MapValue.haven: 1.06, //modified
    MapValue.fracture: 1.21, //modified
    MapValue.abyss: 1.138, //modified
    MapValue.pearl: 1.11, //modified
    MapValue.corrode: 0.985,
    MapValue.summit: 1.03,
  };

  /// The SVG view boxes used by Icarus's attack-side map assets.
  static const Map<MapValue, Size> mapViewBox = {
    MapValue.ascent: Size(411, 474),
    MapValue.breeze: Size(447, 473),
    MapValue.lotus: Size(493, 473),
    MapValue.icebox: Size(387, 473),
    MapValue.sunset: Size(416, 473),
    MapValue.split: Size(467, 473),
    MapValue.haven: Size(393, 473),
    MapValue.fracture: Size(460, 473),
    MapValue.abyss: Size(454, 473),
    MapValue.pearl: Size(469, 473),
    MapValue.bind: Size(416, 474),
    MapValue.corrode: Size(387, 473),
    MapValue.summit: Size(435, 473),
  };

  /// Native 1024px display-icon frame registered to the unchanged SVG fill.
  /// Negative insets preserve the SVG's blank margins. Fits use held-out wall
  /// corners, independently of the navigation and visibility geometry.
  static const Map<MapValue, EdgeInsets> visionGeometryPadding = {
    MapValue.abyss: EdgeInsets.fromLTRB(
        6.328675204, -3.858243345, 5.060135526, -3.752945925),
    MapValue.ascent: EdgeInsets.fromLTRB(
        39.459896632, 0.576584029, 20.526169337, -3.590518060),
    MapValue.bind: EdgeInsets.fromLTRB(
        40.987741089, -12.824899665, 5.514732340, 1.327373095),
    MapValue.breeze: EdgeInsets.fromLTRB(
        14.430969120, -2.990245020, 14.038489819, 5.459703959),
    MapValue.corrode: EdgeInsets.fromLTRB(
        36.004978818, -3.605634982, 35.279108942, -11.110277258),
    MapValue.fracture: EdgeInsets.fromLTRB(
        10.666706978, 16.990962355, 37.599454022, 18.275198645),
    MapValue.haven: EdgeInsets.fromLTRB(
        36.158961943, -2.220452283, 38.612779353, -3.007806421),
    MapValue.icebox: EdgeInsets.fromLTRB(
        34.705323332, -17.412137864, 44.416631700, 10.534092896),
    MapValue.lotus: EdgeInsets.fromLTRB(
        30.239788609, 48.210572803, 37.247980400, 39.277196206),
    MapValue.pearl: EdgeInsets.fromLTRB(
        1.041834592, -0.954569116, 1.609264747, -0.394331545),
    MapValue.split: EdgeInsets.fromLTRB(
        13.039474558, 8.325890212, 21.193894170, 19.907478516),
    MapValue.sunset: EdgeInsets.fromLTRB(
        18.426333102, -14.029381227, 11.371333345, -13.172952326),
    MapValue.summit: EdgeInsets.fromLTRB(
        16.856280276, -10.367397066, 1.093173289, -9.683149369),
  };

  /// Registration is encoded completely in the icon frame above. Identity
  /// values retain the existing projection contract without double correction.
  static const Map<MapValue, VisionGeometryAlignment> visionGeometryAlignment =
      {
    MapValue.ascent: VisionGeometryAlignment(),
    MapValue.breeze: VisionGeometryAlignment(),
    MapValue.lotus: VisionGeometryAlignment(),
    MapValue.icebox: VisionGeometryAlignment(),
    MapValue.sunset: VisionGeometryAlignment(),
    MapValue.split: VisionGeometryAlignment(),
    MapValue.haven: VisionGeometryAlignment(),
    MapValue.fracture: VisionGeometryAlignment(),
    MapValue.abyss: VisionGeometryAlignment(),
    MapValue.pearl: VisionGeometryAlignment(),
    MapValue.bind: VisionGeometryAlignment(),
    MapValue.corrode: VisionGeometryAlignment(),
    MapValue.summit: VisionGeometryAlignment(),
  };

  /// Quarter turns required to align Riot's VisionGeometry tables with the
  /// attack-side SVGs. These values were verified against the SVG wall paths.
  static const Map<MapValue, int> visionGeometryCwQuarterTurns = {
    MapValue.abyss: 1,
    MapValue.ascent: 1,
    MapValue.corrode: 1,
    MapValue.haven: 1,
    MapValue.icebox: 3,
    MapValue.split: 1,
  };

  static bool hasVisionGeometry(MapValue map) =>
      visionGeometryPadding.containsKey(map);
}
