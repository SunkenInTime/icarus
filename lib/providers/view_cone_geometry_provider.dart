import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/map_artwork_registration.dart';
import 'package:icarus/providers/vision_boundary_editor_provider.dart';
import 'package:icarus/providers/navigation_geometry_provider.dart';
import 'package:icarus/providers/world_geometry_source_provider.dart';
import 'package:icarus/view_cone/authored_vision_boundary.dart';
import 'package:icarus/view_cone/svg_vision_boundary.dart';
import 'package:icarus/view_cone/vision_boundary_edit_document.dart';
import 'package:icarus/view_cone/vision_geometry.dart';
import 'package:icarus/view_cone/height_catalog.dart';

export 'package:icarus/providers/world_geometry_source_provider.dart';

final viewConeGeometryProvider =
    FutureProvider.autoDispose.family<VisionGeometryMap?, MapValue>(
  _loadViewConeGeometry,
);

Future<VisionGeometryMap?> _loadViewConeGeometry(
  Ref ref,
  MapValue map,
) async {
  if (!Maps.hasVisionGeometry(map)) return null;
  // A read-only path request must finish loading even without a widget watcher.
  // Afterwards active consumers retain the map; inactive maps release its data.
  final keepAlive = ref.keepAlive();
  try {
    return await _loadViewConeGeometrySource(ref, map);
  } finally {
    keepAlive.close();
  }
}

Future<VisionGeometryMap?> _loadViewConeGeometrySource(
  Ref ref,
  MapValue map,
) async {
  if (ref.watch(worldGeometryEnabledProvider(map))) {
    final navigation = await ref.watch(navigationGeometryProvider(map).future);
    final entry = (await loadHeightCatalog())[map]!;
    return VisionGeometryMap.forStandingHeight(
      map: map,
      navigationGeometry: navigation!.geometry,
      observerHeight: entry.observerHeightCm,
      defaultElevation: entry.defaultFloorElevationCm + entry.observerHeightCm,
      elevations: entry.menuElevationsCm,
    );
  }

  final editorDraft = ref.watch(
    visionBoundaryEditorProvider.select(
      (state) => state.map == map ? state.committedDraft : null,
    ),
  );
  final mapName = Maps.mapNames[map]!;
  final sources = await Future.wait([
    rootBundle.loadString('assets/maps/${mapName}_vision.json'),
    rootBundle.loadString('assets/maps/${mapName}_map.svg'),
    rootBundle.loadString('assets/maps/${mapName}_map_defense.svg'),
    rootBundle.loadString('assets/maps/vision_boundary_additions.json'),
    rootBundle.loadString(visionBoundaryEditsAsset),
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
      sourceTranslationSvg: -mapDefenseArtworkOffsetSvg[map]!,
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
    var edits = await compute(_decodeVisionGeometry, sources[4]);
    if (editorDraft != null) {
      edits = withVisionBoundaryDraft(
        document: edits,
        draft: editorDraft,
      );
    }
    final maps = edits['maps'];
    if (maps is! Map<String, dynamic>) {
      throw const FormatException('Invalid collision edit manifest.');
    }
    if (maps.containsKey(map.name)) {
      attackBoundary = AuthoredVisionBoundary.parse(
        map: map,
        document: edits,
        attackTargetBounds: svgAttackBoundary.outerGroup.bounds,
      );
      defenseBoundary = AuthoredVisionBoundary.parse(
        map: map,
        document: edits,
        attackTargetBounds: svgAttackBoundary.outerGroup.bounds,
        isDefense: true,
      );
    }
  } on Object catch (error) {
    debugPrint(
      'Unable to load manual boundary edits; using exact SVG boundary: '
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
}

Map<String, dynamic> _decodeVisionGeometry(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Vision geometry asset must be an object.');
  }
  return decoded;
}
