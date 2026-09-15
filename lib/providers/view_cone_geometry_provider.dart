import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/map_artwork_registration.dart';
import 'package:icarus/page_transition/navigation_geometry.dart';
import 'package:icarus/providers/vision_boundary_editor_provider.dart';
import 'package:icarus/providers/navigation_geometry_provider.dart';
import 'package:icarus/providers/world_geometry_source_provider.dart';
import 'package:icarus/view_cone/authored_vision_boundary.dart';
import 'package:icarus/view_cone/svg_vision_boundary.dart';
import 'package:icarus/view_cone/vision_boundary_edit_document.dart';
import 'package:icarus/view_cone/vision_geometry.dart';
import 'package:icarus/view_cone/height_assets.dart';
import 'package:icarus/view_cone/vision_world_binary.dart';
import 'package:icarus/view_cone/verified_world_chunks.dart';
import 'package:icarus/view_cone/vision_world_gzip.dart';

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

Future<VisionGeometryMap> loadWorldViewConeGeometry(
  MapValue map, {
  AssetBundle? bundle,
  bool binary = false,
  bool chunked = false,
  NavigationGeometry? navigationGeometry,
}) async {
  final assets = bundle ?? rootBundle;
  if (chunked) {
    return _loadChunkedWorldGeometry(map, assets, navigationGeometry);
  }
  final sources = await Future.wait([
    assets.load(
        'assets/maps/world/${map.name}_visibility.${binary ? 'bin' : 'json'}.gz'),
    if (navigationGeometry == null)
      assets.load('assets/maps/world/${map.name}_navigation.json.gz'),
  ]);
  return compute(_decodeWorldMap, (
    map: map,
    binary: binary,
    visibility: sources[0]
        .buffer
        .asUint8List(sources[0].offsetInBytes, sources[0].lengthInBytes),
    parsedNavigation: navigationGeometry,
    manifest: null,
    chunks: null,
    navigation: navigationGeometry != null
        ? null
        : sources[1]
            .buffer
            .asUint8List(sources[1].offsetInBytes, sources[1].lengthInBytes),
  ));
}

Future<VisionGeometryMap> _decodeWorldMap(
  ({
    MapValue map,
    bool binary,
    Uint8List visibility,
    Uint8List? navigation,
    NavigationGeometry? parsedNavigation,
    Map<String, dynamic>? manifest,
    Map<String, Uint8List>? chunks,
  }) source,
) async {
  Map<String, dynamic> decode(Uint8List bytes) =>
      _decodeVisionGeometry(utf8.decode(decodeWorldGzip(bytes)));
  final navigationJson =
      source.parsedNavigation == null ? decode(source.navigation!) : null;
  if (navigationJson != null && navigationJson['map'] != source.map.name) {
    throw const FormatException('Navigation geometry map mismatch.');
  }
  final navigation = source.parsedNavigation ??
      NavigationGeometry.fromJson(
        navigationJson!,
        projectUv: (uv) => VisionGeometryMap.projectUv(source.map, uv),
      );
  final visibility = source.manifest ??
      (source.binary
          ? decodeVisionWorldBinary(decodeWorldGzip(source.visibility))
          : decode(source.visibility));
  final geometry = VisionGeometryMap.fromWorldJson(
    source.map,
    visibility,
    navigationGeometry: navigation,
    compressedChunks: source.chunks == null
        ? null
        : await VerifiedWorldChunks.verify(source.manifest!, source.chunks!),
  );
  // Prepare the first visible floors off the UI thread with asset decoding.
  geometry.layerFor(isAttack: true);
  geometry.layerFor(isAttack: false);
  return geometry;
}

Future<VisionGeometryMap> _loadChunkedWorldGeometry(MapValue map,
    AssetBundle assets, NavigationGeometry? navigationGeometry) async {
  final manifest = _decodeVisionGeometry(await assets
      .loadString('assets/maps/world/${map.name}_visibility.manifest.json'));
  final descriptors = manifest['chunks'];
  if (manifest['format'] != 'chunked-v1' ||
      descriptors is! List ||
      descriptors.isEmpty) {
    throw const FormatException('Invalid chunked world asset manifest.');
  }
  final names = <String>[];
  for (final descriptor in descriptors) {
    final name =
        descriptor is Map<String, dynamic> ? descriptor['asset'] : null;
    if (name is! String ||
        !RegExp(r'^[a-z0-9_-]+\.bin\.gz$').hasMatch(name) ||
        names.contains(name)) {
      throw const FormatException('Invalid world chunk asset name.');
    }
    names.add(name);
  }
  final sources = await Future.wait([
    for (final name in names) assets.load('assets/maps/world/$name'),
    if (navigationGeometry == null)
      assets.load('assets/maps/world/${map.name}_navigation.json.gz'),
  ]);
  Uint8List bytes(ByteData data) =>
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  return compute(_decodeWorldMap, (
    map: map,
    binary: true,
    visibility: Uint8List(0),
    parsedNavigation: navigationGeometry,
    navigation: navigationGeometry == null ? bytes(sources.last) : null,
    manifest: manifest,
    chunks: {
      for (var i = 0; i < names.length; i++) names[i]: bytes(sources[i])
    },
  ));
}

Map<String, dynamic> _decodeVisionGeometry(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Vision geometry asset must be an object.');
  }
  return decoded;
}
