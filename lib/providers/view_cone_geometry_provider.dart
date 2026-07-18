import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/authored_vision_boundary.dart';
import 'package:icarus/view_cone/svg_vision_boundary.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

final viewConeGeometryProvider =
    FutureProvider.family<VisionGeometryMap?, MapValue>((ref, map) async {
  if (!Maps.hasVisionGeometry(map)) return null;

  final mapName = Maps.mapNames[map]!;
  final sources = await Future.wait([
    rootBundle.loadString('assets/maps/${mapName}_vision.json'),
    rootBundle.loadString('assets/maps/${mapName}_map.svg'),
    rootBundle.loadString('assets/maps/${mapName}_map_defense.svg'),
    rootBundle.loadString('assets/maps/vision_boundary_additions.json'),
  ]);
  final decoded = await compute(_decodeVisionGeometry, sources[0]);
  final geometry = VisionGeometryMap.fromCompactJson(map, decoded);
  var overrides = const VisionGeometryOverrides();
  var additions = const VisionBoundaryAdditions();
  try {
    additions = VisionBoundaryAdditions.fromJson(
      _decodeVisionGeometry(sources[3]),
    );
    overrides = overrides.merge(
      VisionGeometryOverrides(
        attack: additions.overridesFor(map, isAttack: true),
        defense: additions.overridesFor(map, isAttack: false),
      ),
    );
  } on Object catch (error) {
    debugPrint('Ignoring invalid vision boundary additions: $error');
  }
  try {
    final overrideSource = await rootBundle.loadString(
      'assets/maps/vision_contour_overrides.json',
    );
    overrides = overrides.merge(
      VisionGeometryOverrides.fromJson(
        map,
        _decodeVisionGeometry(overrideSource),
      ),
    );
  } on Object catch (error) {
    debugPrint('Ignoring invalid vision contour overrides: $error');
  }
  late final VisionBoundary svgAttackBoundary;
  late final VisionBoundary svgDefenseBoundary;
  try {
    svgAttackBoundary = SvgVisionBoundary.parse(
      map: map,
      source: sources[1],
      additions: additions,
      isAttack: true,
    );
    svgDefenseBoundary = SvgVisionBoundary.parse(
      map: map,
      source: sources[2],
      additions: additions,
      isAttack: false,
    );
  } on Object catch (error) {
    debugPrint('Unable to load SVG vision boundary: $error');
    // Raw Riot coordinates must never become a silent runtime fallback: the
    // hand-authored SVG is the authoritative visual coordinate system.
    return null;
  }
  var attackBoundary = svgAttackBoundary;
  var defenseBoundary = svgDefenseBoundary;
  try {
    final referenceSource = await rootBundle.loadString(
      'assets/maps/vision_collision_reference.json',
    );
    final reference = await compute(_decodeVisionGeometry, referenceSource);
    attackBoundary = AuthoredVisionBoundary.parse(
      map: map,
      document: reference,
      attackTargetBounds: svgAttackBoundary.outerGroup.bounds,
    );
    defenseBoundary = AuthoredVisionBoundary.parse(
      map: map,
      document: reference,
      attackTargetBounds: svgAttackBoundary.outerGroup.bounds,
      isDefense: true,
    );
  } on Object catch (error) {
    debugPrint(
      'Unable to load authored collision reference; using SVG boundary: '
      '$error',
    );
  }
  try {
    return geometry.withSvgBoundaries(
      attackBoundary: attackBoundary,
      defenseBoundary: defenseBoundary,
      overrides: overrides,
    );
  } on FormatException catch (error) {
    if (overrides.isEmpty) {
      debugPrint('Unable to classify SVG vision contours: $error');
      return null;
    }
    debugPrint('Ignoring invalid map-specific contour overrides: $error');
    return geometry.withSvgBoundaries(
      attackBoundary: attackBoundary,
      defenseBoundary: defenseBoundary,
    );
  }
});

Map<String, dynamic> _decodeVisionGeometry(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Vision geometry asset must be an object.');
  }
  return decoded;
}
