import 'dart:convert';
import 'dart:io';

import 'package:cryptography_plus/dart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/page_transition/navigation_geometry.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

void main() {
  test('compare mapped source-parent routes on every map', () {
    const fixtures = String.fromEnvironment('NAV_BENCHMARK_FIXTURES');
    const output = String.fromEnvironment('NAV_BENCHMARK_OUTPUT');
    final input = jsonDecode(File(fixtures).readAsStringSync()) as Map;
    final results = <Map<String, Object?>>[];
    var totalMismatches = 0;
    for (final row in input['maps'] as List) {
      final map = MapValue.values.byName(row['map'] as String);
      Offset project(List uv) => VisionGeometryMap.projectUv(
          map, Offset((uv[0] as num).toDouble(), (uv[1] as num).toDouble()));
      final models = <String, NavigationGeometry>{};
      final decode = <String, Object?>{};
      for (final mode in ['baseline', 'candidate']) {
        final rssBefore = ProcessInfo.currentRss;
        final watch = Stopwatch()..start();
        final bytes = File(row[mode] as String).readAsBytesSync();
        final readUs = watch.elapsedMicroseconds;
        final digest = const DartSha256()
            .hashSync(bytes)
            .bytes
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join();
        expect(digest, row['${mode}Sha256']);
        watch.reset();
        final unpacked = gzip.decode(bytes);
        final data = jsonDecode(utf8.decode(unpacked)) as Map<String, dynamic>;
        final parseUs = watch.elapsedMicroseconds;
        watch.reset();
        final geometry = NavigationGeometry.fromJson(data,
            projectUv: (uv) => VisionGeometryMap.projectUv(map, uv));
        final indexUs = watch.elapsedMicroseconds;
        models[mode] = geometry;
        decode[mode] = {
          'compressedBytes': bytes.length,
          'decodedJsonBytes': unpacked.length,
          'readUs': readUs,
          'gzipJsonDecodeUs': parseUs,
          'geometryIndexUs': indexUs,
          'decodeAndIndexUs': parseUs + indexUs,
          'rssBeforeBytes': rssBefore,
          'rssAfterDecodeBytes': ProcessInfo.currentRss,
          'vertices': geometry.vertices.length,
          'polygons': geometry.polygons.length,
          'triangles': geometry.triangles.length,
          'portals': geometry.links.length,
          'floorVertices': (data['floorMesh']['vertices'] as List).length ~/ 3,
          'floorTriangles':
              (data['floorMesh']['triangles'] as List).length ~/ 4,
        };
      }
      final times = <String, List<int>>{'baseline': [], 'candidate': []};
      final reachable = <String, int>{'baseline': 0, 'candidate': 0};
      final pointCounts = <String, int>{'baseline': 0, 'candidate': 0};
      final mismatches = <Object?>[];
      final pairs = row['pairs'] as List;
      final warmup = row['warmupPairs'] as int;
      for (var i = 0; i < pairs.length; i++) {
        final pair = pairs[i] as List;
        final start = pair[0] as Map, end = pair[1] as Map;
        final outcomes = <String, bool>{};
        for (final mode in (i.isEven
            ? ['baseline', 'candidate']
            : ['candidate', 'baseline'])) {
          final key = mode == 'baseline' ? 'sourceUv' : 'candidateUv';
          final watch = Stopwatch()..start();
          final route = models[mode]!.findRoute(
              start: project(start[key] as List),
              end: project(end[key] as List),
              startFloorHeight: (start['preferredFloorCm'] as num).toDouble(),
              endFloorHeight: (end['preferredFloorCm'] as num).toDouble());
          final elapsed = watch.elapsedMicroseconds;
          outcomes[mode] = route.isReachable;
          if (i >= warmup) {
            if (route.isReachable) {
              times[mode]!.add(elapsed);
              reachable[mode] = reachable[mode]! + 1;
              pointCounts[mode] = pointCounts[mode]! + route.points.length;
            }
          }
        }
        if (outcomes['baseline'] != outcomes['candidate']) {
          mismatches.add({'pair': pair, 'outcomes': outcomes});
        }
      }
      Map<String, Object> stats(String mode) {
        final samples = times[mode]!..sort();
        expect(samples.length, greaterThan(250));
        return {
          'reachableSamples': reachable[mode]!,
          'p50Us': samples[(samples.length * .5).floor()],
          'p95Us': samples[(samples.length * .95).floor()],
          'maxUs': samples.last,
          'averageRoutePointCount': pointCounts[mode]! / samples.length,
        };
      }

      final result = <String, Object?>{
        'map': map.name,
        'decode': decode,
        'baseline': stats('baseline'),
        'candidate': stats('candidate'),
        'sameParentEndpointPairs': pairs.length,
        'reachabilityMismatches': mismatches,
      };
      results.add(result);
      totalMismatches += mismatches.length;
      File(output)
          .writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
        'scope': 'Flutter test debug/JIT, interleaved routes after 50 warmup pairs. '
            'Cold decode is first per-file decode in this process, not an AOT startup claim. '
            'RSS includes runtime, temporary JSON and earlier maps; it is not retained model heap.',
        'maps': results,
      }));
      // ignore: avoid_print
      print(jsonEncode(result));
    }
    expect(totalMismatches, 0);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
