import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/svg_vision_boundary.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

final viewConeGeometryProvider =
    FutureProvider.family<VisionGeometryMap?, MapValue>(
  (ref, map) async {
    if (!Maps.hasVisionGeometry(map)) return null;

    final mapName = Maps.mapNames[map]!;
    final sources = await Future.wait([
      rootBundle.loadString('assets/maps/${mapName}_vision.json'),
      rootBundle.loadString('assets/maps/${mapName}_map.svg'),
      rootBundle.loadString('assets/maps/${mapName}_map_defense.svg'),
    ]);
    final decoded = await compute(_decodeVisionGeometry, sources[0]);
    final geometry = VisionGeometryMap.fromCompactJson(map, decoded);
    try {
      return geometry.withSvgBoundaries(
        attackBoundary: SvgVisionBoundary.parse(
          map: map,
          source: sources[1],
        ),
        defenseBoundary: SvgVisionBoundary.parse(
          map: map,
          source: sources[2],
        ),
      );
    } on FormatException catch (error) {
      debugPrint('Unable to load SVG vision boundary: $error');
      return geometry;
    }
  },
);

Map<String, dynamic> _decodeVisionGeometry(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Vision geometry asset must be an object.');
  }
  return decoded;
}
