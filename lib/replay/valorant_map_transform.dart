import 'dart:math' as math;
import 'dart:ui';

import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';

class ValorantMapTransform {
  const ValorantMapTransform({
    required this.xMultiplier,
    required this.yMultiplier,
    required this.xScalarToAdd,
    required this.yScalarToAdd,
  });

  final double xMultiplier;
  final double yMultiplier;
  final double xScalarToAdd;
  final double yScalarToAdd;
}

class ValorantMapTransforms {
  static const Map<String, MapValue> riotMapIdToMapValue = {
    '/Game/Maps/Ascent/Ascent': MapValue.ascent,
    '/Game/Maps/Bonsai/Bonsai': MapValue.split,
    '/Game/Maps/Canyon/Canyon': MapValue.fracture,
    '/Game/Maps/Duality/Duality': MapValue.bind,
    '/Game/Maps/Foxtrot/Foxtrot': MapValue.breeze,
    '/Game/Maps/Infinity/Infinity': MapValue.abyss,
    '/Game/Maps/Jam/Jam': MapValue.lotus,
    '/Game/Maps/Juliett/Juliett': MapValue.sunset,
    '/Game/Maps/Pitt/Pitt': MapValue.pearl,
    '/Game/Maps/Port/Port': MapValue.icebox,
    '/Game/Maps/Rook/Rook': MapValue.corrode,
    '/Game/Maps/Triad/Triad': MapValue.haven,
  };

  static const Map<MapValue, ValorantMapTransform> mapTransforms = {
    MapValue.ascent: ValorantMapTransform(
      xMultiplier: 0.00007,
      yMultiplier: -0.00007,
      xScalarToAdd: 0.813895,
      yScalarToAdd: 0.573242,
    ),
    MapValue.bind: ValorantMapTransform(
      xMultiplier: 0.000078,
      yMultiplier: -0.000078,
      xScalarToAdd: 0.842188,
      yScalarToAdd: 0.697578,
    ),
    MapValue.breeze: ValorantMapTransform(
      xMultiplier: 0.00007,
      yMultiplier: -0.00007,
      xScalarToAdd: 0.465123,
      yScalarToAdd: 0.833078,
    ),
    MapValue.fracture: ValorantMapTransform(
      xMultiplier: 0.000078,
      yMultiplier: -0.000078,
      xScalarToAdd: 0.556952,
      yScalarToAdd: 1.155886,
    ),
    MapValue.split: ValorantMapTransform(
      xMultiplier: 0.000059,
      yMultiplier: -0.000059,
      xScalarToAdd: 0.576941,
      yScalarToAdd: 0.967566,
    ),
    MapValue.icebox: ValorantMapTransform(
      xMultiplier: 0.000072,
      yMultiplier: -0.000072,
      xScalarToAdd: 0.460214,
      yScalarToAdd: 0.304687,
    ),
    MapValue.lotus: ValorantMapTransform(
      xMultiplier: 0.000072,
      yMultiplier: -0.000072,
      xScalarToAdd: 0.454789,
      yScalarToAdd: 0.917752,
    ),
    MapValue.sunset: ValorantMapTransform(
      xMultiplier: 0.000078,
      yMultiplier: -0.000078,
      xScalarToAdd: 0.5,
      yScalarToAdd: 0.515625,
    ),
    MapValue.pearl: ValorantMapTransform(
      xMultiplier: 0.000078,
      yMultiplier: -0.000078,
      xScalarToAdd: 0.480469,
      yScalarToAdd: 0.916016,
    ),
    MapValue.abyss: ValorantMapTransform(
      xMultiplier: 0.000081,
      yMultiplier: -0.000081,
      xScalarToAdd: 0.5,
      yScalarToAdd: 0.5,
    ),
    MapValue.corrode: ValorantMapTransform(
      xMultiplier: 0.00007,
      yMultiplier: -0.00007,
      xScalarToAdd: 0.526158,
      yScalarToAdd: 0.5,
    ),
    MapValue.haven: ValorantMapTransform(
      xMultiplier: 0.000075,
      yMultiplier: -0.000075,
      xScalarToAdd: 1.09345,
      yScalarToAdd: 0.642728,
    ),
  };

  static const Map<MapValue, int> importCwQuarterTurns = {
    MapValue.abyss: 1,
    MapValue.ascent: 1,
    MapValue.corrode: 1,
    MapValue.haven: 1,
    MapValue.icebox: 1,
    MapValue.split: 1,
  };

  static MapValue? mapValueFromAnyId(String? mapIdOrName) {
    if (mapIdOrName == null) return null;
    final trimmed = mapIdOrName.trim();
    if (trimmed.isEmpty) return null;

    final byRiotId = riotMapIdToMapValue[trimmed];
    if (byRiotId != null) return byRiotId;

    final normalized = trimmed.toLowerCase();
    for (final entry in Maps.mapNames.entries) {
      if (entry.value.toLowerCase() == normalized) {
        return entry.key;
      }
    }
    return null;
  }

  static Offset gameToIcarus({
    required MapValue map,
    required double gameX,
    required double gameY,
  }) {
    final transform = mapTransforms[map];
    if (transform == null) {
      return Offset(gameX, gameY);
    }

    final rawU = (gameY * transform.xMultiplier) + transform.xScalarToAdd;
    final rawV = (gameX * transform.yMultiplier) + transform.yScalarToAdd;
    final rotated = rotateUvCw(
      u: rawU,
      v: rawV,
      turns: importCwQuarterTurns[map] ?? 0,
    );

    return valorantPaddedPercentToIcarus(
      map: map,
      u: rotated.u,
      v: rotated.v,
    );
  }

  static double gameYawToCanvasRadians({
    required MapValue map,
    required double gameX,
    required double gameY,
    required double yawDegrees,
  }) {
    final radians = yawDegrees * math.pi / 180.0;
    final start = gameToIcarus(map: map, gameX: gameX, gameY: gameY);
    final end = gameToIcarus(
      map: map,
      gameX: gameX + math.cos(radians) * 100,
      gameY: gameY + math.sin(radians) * 100,
    );
    final delta = end - start;
    if (delta.distance == 0) return radians;
    return math.atan2(delta.dy, delta.dx);
  }

  static Offset percentToIcarus({required double u, required double v}) {
    final coordinateSystem = CoordinateSystem.instance;
    return Offset(
      coordinateSystem.mapPaddingNormalizedX +
          (u.clamp(0.0, 1.0) * coordinateSystem.mapNormalizedWidth),
      v.clamp(0.0, 1.0) * coordinateSystem.normalizedHeight,
    );
  }

  static Offset valorantPaddedPercentToIcarus({
    required MapValue map,
    required double u,
    required double v,
  }) {
    final viewBoxSize = Maps.mapViewBox[map];
    final padding = Maps.valorantDisplayIconPaddingVb[map];
    if (viewBoxSize == null || padding == null) {
      return percentToIcarus(u: u, v: v);
    }

    final coordinateSystem = CoordinateSystem.instance;
    final paddedWidth = viewBoxSize.width + padding.left + padding.right;
    final paddedHeight = viewBoxSize.height + padding.top + padding.bottom;
    final svgX = (u * paddedWidth - padding.left)
        .clamp(0.0, viewBoxSize.width)
        .toDouble();
    final svgY = (v * paddedHeight - padding.top)
        .clamp(0.0, viewBoxSize.height)
        .toDouble();
    final scale = math.min(
      coordinateSystem.mapNormalizedWidth / viewBoxSize.width,
      coordinateSystem.normalizedHeight / viewBoxSize.height,
    );
    final renderedWidth = viewBoxSize.width * scale;
    final renderedHeight = viewBoxSize.height * scale;
    final offsetX = (coordinateSystem.mapNormalizedWidth - renderedWidth) / 2;
    final offsetY = (coordinateSystem.normalizedHeight - renderedHeight) / 2;

    return Offset(
      coordinateSystem.mapPaddingNormalizedX + offsetX + svgX * scale,
      offsetY + svgY * scale,
    );
  }

  static ({double u, double v}) rotateUvCw({
    required double u,
    required double v,
    required int turns,
  }) {
    final t = turns % 4;
    if (t == 0) return (u: u, v: v);
    if (t == 1) return (u: 1.0 - v, v: u);
    if (t == 2) return (u: 1.0 - u, v: 1.0 - v);
    return (u: v, v: 1.0 - u);
  }
}
