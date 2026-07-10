import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

final viewConeGeometryProvider =
    FutureProvider.family<VisionGeometryMap?, MapValue>((ref, map) async {
      if (!Maps.hasVisionGeometry(map)) return null;

      final mapName = Maps.mapNames[map]!;
      final source = await rootBundle.loadString(
        'assets/maps/${mapName}_vision.json',
      );
      final decoded = await compute(_decodeVisionGeometry, source);
      return VisionGeometryMap.fromCompactJson(map, decoded);
    });

Map<String, dynamic> _decodeVisionGeometry(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Vision geometry asset must be an object.');
  }
  return decoded;
}
