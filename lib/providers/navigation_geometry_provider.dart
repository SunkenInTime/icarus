import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/page_transition/navigation_geometry.dart';
import 'package:icarus/page_transition/navigation_geometry_map.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/world_geometry_source_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/view_cone/vision_geometry.dart';
import 'package:icarus/view_cone/height_assets.dart';
import 'package:icarus/view_cone/vision_world_gzip.dart';

final navigationGeometryBundleProvider =
    Provider<AssetBundle>((ref) => rootBundle);

final navigationGeometryProvider = FutureProvider.autoDispose
    .family<NavigationGeometryMap?, MapValue>((ref, map) async {
  if (!ref.watch(worldGeometryEnabledProvider(map))) return null;
  final retain = ref.keepAlive();
  var loaded = false;
  var disposed = false;
  ref.onDispose(() => disposed = true);
  ref.listen(mapProvider.select((state) => state.currentMap),
      (before, current) {
    if (loaded && current != map) retain.close();
  });
  try {
    return await loadNavigationGeometry(map,
        bundle: ref.watch(navigationGeometryBundleProvider));
  } catch (error, stackTrace) {
    AppErrorReporter.reportError(
      'Could not load movement paths for ${map.name}.',
      error: error,
      stackTrace: stackTrace,
      source: 'navigationGeometryProvider.${map.name}',
    );
    rethrow;
  } finally {
    loaded = true;
    if (!disposed && ref.read(mapProvider).currentMap != map) retain.close();
  }
});

Future<NavigationGeometryMap> loadNavigationGeometry(MapValue map,
    {AssetBundle? bundle}) async {
  final entry = (await loadHeightCatalog(bundle: bundle))[map]!;
  final data = await loadVerifiedHeightNavigation(map,
      bundle: bundle, catalogEntry: entry);
  return compute(_decodeNavigation, (
    map: map,
    bytes: data,
    defenseOffset: entry.defenseOffsetCanvas,
    additionalCharts: entry.variants.length,
  ));
}

NavigationGeometryMap _decodeNavigation(
    ({
      MapValue map,
      Uint8List bytes,
      Offset defenseOffset,
      int additionalCharts
    }) source) {
  final decoded = jsonDecode(utf8.decode(decodeWorldGzip(source.bytes)));
  if (decoded is! Map<String, dynamic> || decoded['map'] != source.map.name) {
    throw const FormatException('Navigation geometry map mismatch.');
  }
  final eye = decoded['observerHeightCm'];
  final floor = decoded['defaultFloorElevationCm'];
  if (eye is! num ||
      !eye.isFinite ||
      eye <= 0 ||
      floor is! num ||
      !floor.isFinite) {
    throw const FormatException('Invalid navigation standing-height defaults.');
  }
  final geometry = NavigationGeometry.fromJson(decoded,
      projectUv: (uv) => VisionGeometryMap.projectUv(source.map, uv));
  if (geometry.maximumGroundChartId > source.additionalCharts) {
    throw const FormatException(
        'Navigation refers to an unavailable ground chart.');
  }
  return NavigationGeometryMap(
    geometry: geometry,
    observerHeightCm: eye.toDouble(),
    defaultFloorElevationCm: floor.toDouble(),
    defenseOffsetCanvas: source.defenseOffset,
  );
}
