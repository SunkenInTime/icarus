import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/page_transition/navigation_geometry.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

/// Run with --dart-define=NAVIGATION_ROOT=.../nav/baked. Uses the real map
/// registration, independent polygon containment, and repeatable random routes.
void main() {
  const root = String.fromEnvironment('NAVIGATION_ROOT');
  const worldRoot = String.fromEnvironment('WORLD_ROOT');
  test('all baked nav meshes route inside their source player polygons', () {
    expect(root, isNotEmpty, reason: 'Supply NAVIGATION_ROOT explicitly');
    final reports = <Map<String, Object>>[];
    for (final map in MapValue.values) {
      final file = File('$root/${map.name}_navigation.json');
      if (!file.existsSync()) continue;
      final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      if (worldRoot.isNotEmpty) {
        final folder = '$worldRoot/${map.name}';
        raw['floorMesh'] =
            (jsonDecode(File('$folder/floor-mesh.json').readAsStringSync())
                as Map<String, dynamic>)['floorMesh'];
        raw['refinedFloorHeightsCm'] = (jsonDecode(
                File('$folder/floor-refinement.json').readAsStringSync())
            as Map<String, dynamic>)['refinedFloorHeightsCm'];
      }
      final watch = Stopwatch()..start();
      final nav = NavigationGeometry.fromJson(raw,
          projectUv: (uv) => VisionGeometryMap.projectUv(map, uv));
      final loadUs = watch.elapsedMicroseconds;
      final componentCounts = <int, int>{};
      for (final c in nav.components.where((c) => c >= 0)) {
        componentCounts[c] = (componentCounts[c] ?? 0) + 1;
      }
      final largest = componentCounts.keys
          .reduce((a, b) => componentCounts[a]! > componentCounts[b]! ? a : b);
      final candidates = [
        for (var i = 0; i < nav.polygons.length; i++)
          if (nav.components[i] == largest) i
      ];
      final polygons = [
        for (final p in nav.polygons)
          [for (final v in p) nav.vertices[v].position]
      ];
      final random = math.Random(73105);
      final times = <int>[];
      var samples = 0, expanded = 0, cachedUs = 0;
      for (var test = 0; test < 250; test++) {
        Offset center(int polygon) =>
            polygons[polygon].reduce((a, b) => a + b) /
            polygons[polygon].length.toDouble();
        final first = candidates[random.nextInt(candidates.length)];
        final last = candidates[random.nextInt(candidates.length)];
        final start = center(first), end = center(last);
        double height(int p) =>
            nav.polygons[p]
                .map((v) => nav.vertices[v].floorHeight)
                .reduce((a, b) => a + b) /
            nav.polygons[p].length;
        watch.reset();
        final route = nav.findRoute(
            start: start,
            end: end,
            startFloorHeight: height(first),
            endFloorHeight: height(last));
        times.add(watch.elapsedMicroseconds);
        expect(route.isReachable, isTrue,
            reason: '${map.name}: $first -> $last');
        expanded += route.expandedPolygons;
        for (var segment = 1; segment < route.points.length; segment++) {
          final a = route.points[segment - 1], b = route.points[segment];
          final steps = ((b - a).distance / .5).ceil().clamp(1, 10000);
          for (var step = 0; step <= steps; step++) {
            final point = Offset.lerp(a, b, step / steps)!;
            expect(candidates.any((p) => contains(polygons[p], point)), isTrue,
                reason:
                    '${map.name} route $first -> $last leaves source floor at $point');
            samples++;
          }
        }
        watch.reset();
        final cached = nav.findRoute(
            start: start,
            end: end,
            startFloorHeight: height(first),
            endFloorHeight: height(last));
        cachedUs += watch.elapsedMicroseconds;
        expect(identical(cached, route), isTrue);
      }
      times.sort();
      final report = <String, Object>{
        'map': map.name,
        'loadUs': loadUs,
        'routes': times.length,
        'p50Us': times[125],
        'p95Us': times[237],
        'maxUs': times.last,
        'cachedAverageUs': cachedUs / times.length,
        'averageExpandedPolygons': expanded / times.length,
        'validatedPoints': samples,
        'polygons': nav.polygons.length,
        'triangles': nav.triangles.length,
        'directedPortals': nav.links.length
      };
      reports.add(report);
      // ignore: avoid_print
      print(jsonEncode(report));
    }
    expect(reports.length, 13);
    final filename = worldRoot.isEmpty
        ? 'runtime-audit.json'
        : 'runtime-audit-with-floors.json';
    File('$root/$filename')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(reports));
  }, timeout: const Timeout(Duration(minutes: 5)));
}

bool contains(List<Offset> polygon, Offset point) {
  var positive = false, negative = false;
  for (var i = 0; i < polygon.length; i++) {
    final a = polygon[i], b = polygon[(i + 1) % polygon.length];
    final value =
        (b.dx - a.dx) * (point.dy - a.dy) - (b.dy - a.dy) * (point.dx - a.dx);
    if (value > .001) positive = true;
    if (value < -.001) negative = true;
  }
  return !positive || !negative;
}
