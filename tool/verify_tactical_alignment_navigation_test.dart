import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:cryptography_plus/dart.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/page_transition/navigation_geometry.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

void main() {
  verifyNavigationCandidate();
}

void verifyNavigationCandidate({String? candidatePath, String? candidateMap}) {
  test(
      '${candidateMap ?? "candidate"} navigation loads and routes inside its floor domains',
      () {
    final candidate =
        candidatePath ?? const String.fromEnvironment('NAVIGATION_CANDIDATE');
    final mapName = candidateMap ??
        const String.fromEnvironment('NAVIGATION_MAP', defaultValue: 'split');
    const sourceOverride = String.fromEnvironment('NAVIGATION_SOURCE');
    final map = MapValue.values.byName(mapName);
    expect(candidate, isNotEmpty);
    final data =
        jsonDecode(utf8.decode(gzip.decode(File(candidate).readAsBytesSync())))
            as Map<String, dynamic>;
    final nav = NavigationGeometry.fromJson(data,
        projectUv: (uv) => VisionGeometryMap.projectUv(map, uv));
    final sourceBytes = File(sourceOverride.isEmpty
            ? 'assets/maps/world/${map.name}_navigation.json.gz'
            : sourceOverride)
        .readAsBytesSync();
    final original = NavigationGeometry.fromJson(
        jsonDecode(utf8.decode(gzip.decode(sourceBytes)))
            as Map<String, dynamic>,
        projectUv: (uv) => VisionGeometryMap.projectUv(map, uv));
    final fixtureFile =
        File('${File(candidate).parent.path}/floor-query-fixtures.json');
    expect(fixtureFile.existsSync(), isTrue);
    var comparedFloors = 0;
    var maximumFloorErrorCm = 0.0;
    final fixture =
        jsonDecode(fixtureFile.readAsStringSync()) as Map<String, dynamic>;
    expect(
        fixture['sourceNavigationSha256'],
        const DartSha256()
            .hashSync(sourceBytes)
            .bytes
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join());
    expect(fixture['map'], map.name);
    for (final row in fixture['samples'] as List) {
      Offset project(List values) => VisionGeometryMap.projectUv(map,
          Offset((values[0] as num).toDouble(), (values[1] as num).toDouble()));
      final preferred = (row['preferredElevationCm'] as num).toDouble();
      final before = original.floorHeightAt(project(row['sourceUv'] as List),
          preferredElevation: preferred);
      final after = nav.floorHeightAt(project(row['candidateUv'] as List),
          preferredElevation: preferred);
      if (before == null) continue;
      expect(after, isNotNull, reason: 'Warp lost a supported floor');
      final error = (before - after!).abs();
      maximumFloorErrorCm = math.max(maximumFloorErrorCm, error);
      expect(error, lessThan(.05),
          reason:
              'Warp changed interpolated floor height $before→$after: $row');
      comparedFloors++;
    }
    expect(comparedFloors, greaterThan(1000));
    final componentCounts = <int, int>{};
    for (var i = 0; i < nav.polygons.length; i++) {
      if (nav.walkable[i])
        componentCounts.update(nav.components[i], (n) => n + 1,
            ifAbsent: () => 1);
    }
    final mainComponent = componentCounts.keys
        .reduce((a, b) => componentCounts[a]! >= componentCounts[b]! ? a : b);
    final ids = [
      for (var i = 0; i < nav.polygons.length; i++)
        if (nav.walkable[i] && nav.components[i] == mainComponent) i
    ];
    final polygons = [
      for (final polygon in nav.polygons)
        [for (final id in polygon) nav.vertices[id].position]
    ];
    Offset center(int p) =>
        polygons[p].reduce((a, b) => a + b) / polygons[p].length.toDouble();
    double height(int p) =>
        nav.polygons[p]
            .map((i) => nav.vertices[i].floorHeight)
            .reduce((a, b) => a + b) /
        nav.polygons[p].length;
    bool contains(List<Offset> polygon, Offset point) {
      var inside = false;
      for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
        final a = polygon[j], b = polygon[i], edge = b - a;
        final along = ((point - a).dx * edge.dx + (point - a).dy * edge.dy) /
            edge.distanceSquared;
        if ((point - (a + edge * along.clamp(0.0, 1.0))).distance < .002)
          return true;
        if ((a.dy > point.dy) != (b.dy > point.dy) &&
            point.dx <
                (b.dx - a.dx) * (point.dy - a.dy) / (b.dy - a.dy) + a.dx) {
          inside = !inside;
        }
      }
      return inside;
    }

    final random = math.Random(12509), timings = <int>[];
    var samples = 0;
    for (var i = 0; i < 100; i++) {
      final a = ids[random.nextInt(ids.length)],
          b = ids[random.nextInt(ids.length)];
      final watch = Stopwatch()..start();
      final route = nav.findRoute(
          start: center(a),
          end: center(b),
          startFloorHeight: height(a),
          endFloorHeight: height(b));
      timings.add(watch.elapsedMicroseconds);
      expect(route.isReachable, isTrue, reason: '$a→$b ${route.failure}');
      for (var segment = 1; segment < route.points.length; segment++) {
        final p = route.points[segment - 1], q = route.points[segment];
        final steps = ((q - p).distance / 2).ceil().clamp(1, 10000);
        for (var k = 0; k <= steps; k++) {
          final sample = Offset.lerp(p, q, k / steps)!;
          expect(ids.any((id) => contains(polygons[id], sample)), isTrue,
              reason: '$a→$b leaves floor at $sample');
          samples++;
        }
      }
    }
    timings.sort();
    // ignore: avoid_print
    print(jsonEncode({
      'polygons': nav.polygons.length,
      'routes': timings.length,
      'samples': samples,
      'p50Us': timings[50],
      'p95Us': timings[95],
      'maxUs': timings.last,
      'comparedFloors': comparedFloors,
      'maximumFloorErrorCm': maximumFloorErrorCm
    }));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
