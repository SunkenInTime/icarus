// Local timing against the same unsimplified 3D slices used by verification.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/vision_geometry.dart';
import 'package:icarus/view_cone/vision_world_index.dart';

void main() {
  test('world slice index preserves full polygons and measures movement costs',
      () {
    const input = String.fromEnvironment('WORLD_SLICE');
    const preview = String.fromEnvironment('WORLD_PREVIEW');
    final slice =
        jsonDecode(File(input).readAsStringSync()) as Map<String, dynamic>;
    final fixture =
        jsonDecode(File(preview).readAsStringSync()) as Map<String, dynamic>;
    final map = MapValue.values.byName(slice['map'] as String);
    final originValues = fixture['preview']['origin'] as List;
    final origin = Offset((originValues[0] as num).toDouble(),
        (originValues[1] as num).toDouble());
    final rows = <Map<String, dynamic>>[];
    for (final plane in slice['slices'] as List) {
      final segments = [
        for (final edge in plane['segmentsUv'] as List)
          VisionSegment(
            VisionGeometryMap.projectUv(
                map,
                Offset((edge[0][0] as num).toDouble(),
                    (edge[0][1] as num).toDouble())),
            VisionGeometryMap.projectUv(
                map,
                Offset((edge[1][0] as num).toDouble(),
                    (edge[1][1] as num).toDouble())),
          ),
      ];
      final timer = Stopwatch()..start();
      final index = VisionWorldIndex(segments);
      final buildMicros = timer.elapsedMicroseconds;
      final indexed = VisionGeometryLayer(
          elevation: 0, segments: segments, worldIndex: index);
      final naive = VisionGeometryLayer(elevation: 0, segments: segments);
      List<Offset> cone(VisionGeometryLayer layer, int i) =>
          VisionPolygon.compute(
            layer: layer,
            origin: origin + Offset(i * .01, i * -.005),
            facingAngle: i * math.pi / 40,
            coneAngle: math.pi * 103 / 180,
            range: 400,
          );
      // Warm the VM before timing. These are deliberately different positions.
      for (var i = -10; i < 0; i++) {
        cone(indexed, i);
        cone(naive, i);
      }
      final indexedTimes = <int>[], naiveTimes = <int>[];
      var vertices = 0;
      for (var i = 0; i < 40; i++) {
        timer.reset();
        final expected = cone(naive, i);
        naiveTimes.add(timer.elapsedMicroseconds);
        timer.reset();
        final actual = cone(indexed, i);
        indexedTimes.add(timer.elapsedMicroseconds);
        expect(actual.length, expected.length);
        for (var p = 0; p < actual.length; p++) {
          expect((actual[p] - expected[p]).distance, lessThan(1e-7));
        }
        vertices += actual.length;
      }
      timer.reset();
      for (var i = 0; i < 1000; i++) {
        cone(indexed, 39);
      }
      final stationaryMicros = timer.elapsedMicroseconds / 1000;
      indexedTimes.sort();
      naiveTimes.sort();
      rows.add({
        'worldElevationMeters': plane['worldElevationMeters'],
        'segments': segments.length,
        'indexBuildMicroseconds': buildMicros,
        'indexedMedianMicroseconds': indexedTimes[20],
        'indexedP95Microseconds': indexedTimes[37],
        'naiveMedianMicroseconds': naiveTimes[20],
        'naiveP95Microseconds': naiveTimes[37],
        'stationaryMeanMicroseconds': stationaryMicros,
        'meanPolygonVertices': vertices / 40,
      });
    }
    final output = File('build/vision-audit/world-visibility-benchmark.json');
    output.parent.createSync(recursive: true);
    output.writeAsStringSync(jsonEncode({
      'source': input,
      'measurements': rows,
      'profile': 'flutter-test JIT, not release device performance'
    }));
    // ignore: avoid_print
    print(jsonEncode(rows));
  });
}
