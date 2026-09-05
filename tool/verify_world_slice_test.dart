// Local prototype: feed exported 3D cross-sections into Icarus's real ray caster.
// No production asset or provider is replaced by this test.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

VisionGeometryMap decodeSegments(MapValue map, List<dynamic> segments) =>
    VisionGeometryMap.fromCompactJson(map, {
      'version': 2,
      'map': map.name,
      'coordinateScale': 1,
      'defaultElevation': 0,
      'layers': [
        {
          'elevation': 0,
          'vertices': [
            for (final s in segments) ...[...s[0], ...s[1]]
          ],
          'edges': [for (var i = 0; i < segments.length * 2; i++) i],
        }
      ],
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('3D slices reproduce Blender hits on both map orientations', () async {
    const worldPath = String.fromEnvironment('WORLD_RAYS');
    const slicePath = String.fromEnvironment('WORLD_SLICE');
    expect(worldPath, isNotEmpty);
    expect(slicePath, isNotEmpty);
    final worldBytes = File(worldPath).readAsBytesSync();
    final world = jsonDecode(utf8.decode(worldBytes)) as Map<String, dynamic>;
    final slice =
        jsonDecode(File(slicePath).readAsStringSync()) as Map<String, dynamic>;
    final hash = await Sha256().hash(worldBytes);
    expect(slice['worldRaysSha256'],
        hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join());
    final map = MapValue.values.singleWhere((m) => m.name == world['map']);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final runtime = await container.read(viewConeGeometryProvider(map).future);
    expect(runtime, isNotNull);
    final fingerprints = <String, String>{};
    for (final path in [
      worldPath,
      slicePath,
      'assets/maps/${map.name}_map.svg',
      'assets/maps/${map.name}_map_defense.svg',
      'assets/maps/vision_boundary_edits.json',
      'assets/maps/vision_boundary_additions.json',
      'assets/maps/vision_contour_overrides.json',
      'lib/const/maps.dart',
      'lib/view_cone/vision_geometry.dart',
      'lib/providers/view_cone_geometry_provider.dart',
    ]) {
      final hash = await Sha256().hash(File(path).readAsBytesSync());
      fingerprints[path] =
          hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    }
    final planes = <double, VisionGeometryMap>{
      for (final p in slice['slices'] as List)
        (p['worldElevationMeters'] as num).toDouble():
            decodeSegments(map, p['segmentsUv'] as List),
    };
    final ids = (slice['rayIds'] as List).toSet();
    final rows = <Map<String, dynamic>>[];
    Map<String, dynamic>? preview;
    for (final ray in world['rays'] as List) {
      if (!ids.contains(ray['id'])) continue;
      final elevation = (ray['startMeters'][2] as num).toDouble();
      final projection = decodeSegments(map, [
        [ray['startUv'], ray['endUv']]
      ]);
      for (final attack in [true, false]) {
        final line = projection.layerFor(isAttack: attack).segments.single;
        final delta = line.end - line.start;
        final range = delta.distance;
        final direction = delta / range;
        final current = runtime!.layerForPosition(
            isAttack: attack,
            position: line.start,
            elevationOverride: elevation * 100);
        final segments = planes[elevation]!.layerFor(isAttack: attack).segments;
        final candidate = VisionGeometryLayer(
          elevation: elevation * 100,
          segments: segments,
          segmentIndex: VisionSegmentIndex(segments),
          // The SVG still controls allowed observer positions. Its outline is
          // absent from the occluders, which come only from the 3D slice.
          boundary: current.boundary,
          observerGroups: current.observerGroups,
          layerIndex: current.layerIndex,
        );
        expect(candidate.contains(line.start), current.contains(line.start));
        if (!candidate.contains(line.start)) continue;
        final polygon = VisionPolygon.compute(
          layer: candidate,
          origin: line.start,
          facingAngle: math.atan2(delta.dy, delta.dx),
          coneAngle: 0.02,
          range: range,
        );
        final center = polygon.skip(1).where((p) {
          final v = p - line.start;
          return (v.dx * direction.dy - v.dy * direction.dx).abs() < 1e-6;
        }).toList();
        expect(center, isNotEmpty);
        final start3d = ray['startMeters'] as List;
        final end3d = ray['endMeters'] as List;
        final worldRange = math.sqrt(List.generate(3, (i) {
          final d = (end3d[i] as num) - (start3d[i] as num);
          return d * d;
        }).reduce((a, b) => a + b));
        final measured =
            center.map((p) => (p - line.start).distance).reduce(math.max) /
                range *
                worldRange;
        final reference = (ray['distanceMeters'] as num).toDouble();
        final error = (measured - reference).abs();
        rows.add({
          'id': ray['id'],
          'attack': attack,
          'sliceDistanceMeters': measured,
          'blenderDistanceMeters': reference,
          'absoluteErrorMeters': error,
          'materialCategory': ray['materialCategory']
        });
        if (attack && ray['id'] == '${slice['sample']}-1.75-18') {
          List<List<double>> points(List<Offset> values) => [
                for (final p in values) [p.dx, p.dy]
              ];
          List<Offset> cone(VisionGeometryLayer layer) => VisionPolygon.compute(
              layer: layer,
              origin: line.start,
              facingAngle: math.atan2(delta.dy, delta.dx),
              coneAngle: math.pi / 2,
              range: range);
          final timer = Stopwatch()..start();
          final candidateCone = cone(candidate);
          timer.stop();
          preview = {
            'id': ray['id'],
            'origin': [line.start.dx, line.start.dy],
            'currentPolygon': points(cone(current)),
            'slicePolygon': points(candidateCone),
            'sliceConeMicroseconds': timer.elapsedMicroseconds,
            'sliceSegments': [
              for (final s in segments) points([s.start, s.end])
            ],
            'runtimeSegments': [
              for (final s in current.segments) points([s.start, s.end])
            ]
          };
        }
      }
    }
    expect(rows.length, ids.length * 2,
        reason:
            'Every selected fixture ray must run on both map orientations.');
    final maximumError =
        rows.map((r) => r['absoluteErrorMeters'] as double).reduce(math.max);
    final result = {
      'status': maximumError < 0.005
          ? '3d-conversion-check-passed'
          : '3d-conversion-check-failed',
      'gameplayCertified': false,
      'map': map.name,
      'rays': rows,
      'maximumErrorMeters': maximumError,
      'worldRaysSha256': slice['worldRaysSha256'],
      'fingerprints': fingerprints,
      'preview': preview
    };
    final output = File('build/vision-audit/${map.name}-slice-prototype.json');
    output.parent.createSync(recursive: true);
    output.writeAsStringSync(jsonEncode(result));
    // ignore: avoid_print
    print(
        '3D slice: ${rows.length} rays, max error ${result['maximumErrorMeters']} m');
    expect(maximumError, lessThan(0.005),
        reason: 'Inspect the saved per-ray report for conversion differences.');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
