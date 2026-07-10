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

  /// Transparent padding removed when the Valorant display icons were
  /// converted into Icarus's cropped SVG map assets.
  static const Map<MapValue, EdgeInsets> visionGeometryPadding = {
    MapValue.abyss: EdgeInsets.fromLTRB(6.82243, 13.64486, 5.457944, 14.099688),
    MapValue.ascent: EdgeInsets.fromLTRB(
      40.111579,
      18.903158,
      21.669474,
      15.214737,
    ),
    MapValue.bind: EdgeInsets.fromLTRB(40.92824, 5.653072, 6.33144, 19.446567),
    MapValue.breeze: EdgeInsets.fromLTRB(
      14.878981,
      14.878981,
      14.878981,
      23.248408,
    ),
    MapValue.corrode: EdgeInsets.fromLTRB(
      36.248848,
      14.320533,
      36.248848,
      6.936508,
    ),
    MapValue.fracture: EdgeInsets.fromLTRB(
      10.912599,
      34.22588,
      38.194098,
      36.706016,
    ),
    MapValue.haven: EdgeInsets.fromLTRB(
      36.63356,
      16.027182,
      39.152117,
      14.882384,
    ),
    MapValue.icebox: EdgeInsets.fromLTRB(
      44.838021,
      28.678125,
      35.733854,
      0.455208,
    ),
    MapValue.lotus: EdgeInsets.fromLTRB(
      30.685893,
      66.303448,
      38.631348,
      57.810031,
    ),
    MapValue.pearl: EdgeInsets.fromLTRB(1.38, 16.56, 2.3, 17.48),
    MapValue.split: EdgeInsets.fromLTRB(
      13.442394,
      25.907159,
      22.485459,
      37.638702,
    ),
    MapValue.sunset: EdgeInsets.fromLTRB(
      20.041874,
      3.921236,
      12.852941,
      5.228315,
    ),
    // Summit was released after the available FModel export. Its Icarus SVG
    // is already tightly cropped, so the generated fallback needs no padding.
    MapValue.summit: EdgeInsets.zero,
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
