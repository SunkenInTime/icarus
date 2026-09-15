import 'dart:ui';

import 'package:icarus/view_cone/vision_world_projection.dart';

Map<String, dynamic> displayWarpFixture({
  VisionWorldProjection? projection,
  Rect bounds = const Rect.fromLTWH(0, 0, 100, 100),
  Offset shift = const Offset(1, 0),
}) {
  final p = projection ??
      VisionWorldProjection(
          origin: Offset.zero,
          axisU: const Offset(1, 0),
          axisV: const Offset(0, 1));
  List<double> xy(Offset v) => [v.dx, v.dy];
  final corners = [
    bounds.topLeft,
    bounds.topRight,
    bounds.bottomRight,
    bounds.bottomLeft
  ];
  final hash = 'a' * 64;
  return {
    'format': 'icarus-display-warp-v1',
    'version': 1,
    'map': 'split',
    'outsideMesh': 'identity-in-source-svg',
    'outerHullMaximumDisplacementSvg': 0,
    'sourceGeometrySha256': hash,
    'maximumStretch': 4,
    'projection': <String, dynamic>{
      'origin': xy(p.origin),
      'axisU': xy(p.axisU),
      'axisV': xy(p.axisV)
    },
    'sourceNativeMeters': [...corners, bounds.center].expand(xy).toList(),
    'targetAttackSvg': [...corners, bounds.center + shift]
        .expand((v) => xy(p.toCanvas(v)))
        .toList(),
    'triangles': [0, 1, 4, 1, 2, 4, 2, 3, 4, 3, 0, 4],
    'attackViewBox': [0, 0, 1000, 1000],
    'defenseViewBox': [0, 0, 1000, 1000],
    'attackToDefenseSvg': <String, dynamic>{
      'axisU': [-1, 0],
      'axisV': [0, -1],
      'origin': [1000, 1000]
    },
    'art': <String, dynamic>{
      'attack': <String, dynamic>{
        'file': 'assets/maps/split_map.svg',
        'sha256': hash
      },
      'defense': <String, dynamic>{
        'file': 'assets/maps/split_map_defense.svg',
        'sha256': hash
      },
    },
    'provenance': {
      for (final key in [
        'warpSha256',
        'compositionProofSha256',
        'sideRegistrationSha256',
        'registrationSha256',
        'controlGeometryPackSha256',
        'unwarpedControlSourcePackSha256'
      ])
        key: hash
    },
  };
}
