// Diagnostic runner, not a gameplay assertion. The reference file is produced
// independently by Blender from exported triangles and remains local.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

Offset projectUv(MapValue map, List<dynamic> uv) {
  // Exercise the production projection through the public decoder, avoiding
  // another copy of its padding, rotation, alignment, or defense transforms.
  final projected = VisionGeometryMap.fromCompactJson(map, {
    'version': 2,
    'map': Maps.mapNames[map],
    'coordinateScale': 1,
    'defaultElevation': 300,
    'layers': [
      {
        'elevation': 300,
        'vertices': [uv[0], uv[1], (uv[0] as num) + 0.001, uv[1]],
        'edges': [0, 1],
      }
    ],
  });
  return projected.attackLayers.first.segments.first.start;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('compares real runtime center rays with independent world triangles',
      () async {
    const sourcePath = String.fromEnvironment('WORLD_RAYS');
    expect(sourcePath, isNotEmpty,
        reason: 'Supply --dart-define=WORLD_RAYS=FILE');
    final source =
        jsonDecode(File(sourcePath).readAsStringSync()) as Map<String, dynamic>;
    final map = MapValue.values.singleWhere((m) => m.name == source['map']);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final runtime = await container.read(viewConeGeometryProvider(map).future);
    expect(runtime, isNotNull);
    final fingerprints = <String, String>{};
    for (final path in [
      sourcePath,
      'assets/maps/${map.name}_vision.json',
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
    final results = <Map<String, dynamic>>[];
    for (final value in source['rays'] as List) {
      final ray = value as Map<String, dynamic>;
      final start = projectUv(map, ray['startUv'] as List);
      final end = projectUv(map, ray['endUv'] as List);
      final delta = end - start;
      final distance = delta.distance;
      expect(distance, greaterThan(0));
      final direction = delta / distance;
      final z = ((ray['startMeters'] as List)[2] as num).toDouble() * 100;
      final layer = runtime!.layerForPosition(
          isAttack: true, position: start, elevationOverride: z);
      final polygon = VisionPolygon.compute(
        layer: layer,
        origin: start,
        facingAngle: math.atan2(delta.dy, delta.dx),
        coneAngle: 0.02,
        range: distance,
      );
      // The production polygon explicitly casts its center ray. Selecting that
      // vertex retains the real stroke and observer-exclusion behavior.
      final center = polygon.skip(1).where((p) {
        final v = p - start;
        final cross = v.dx * direction.dy - v.dy * direction.dx;
        return cross.abs() < 0.000001;
      }).toList();
      final inside = layer.contains(start);
      expect(!inside || center.isNotEmpty, isTrue,
          reason: 'The production polygon must contain its center ray.');
      final worldRange = math.sqrt(List.generate(3, (i) {
        final d = ((ray['endMeters'] as List)[i] as num).toDouble() -
            ((ray['startMeters'] as List)[i] as num).toDouble();
        return d * d;
      }).reduce((a, b) => a + b));
      final runtimeMeters = inside
          ? center.map((p) => (p - start).distance).reduce(math.max) /
              distance *
              worldRange
          : 0.0;
      final referenceMeters = (ray['distanceMeters'] as num).toDouble();
      results.add({
        'id': ray['id'],
        'start': [start.dx, start.dy],
        'end': [end.dx, end.dy],
        'insideRuntimeFootprint': inside,
        'originNearSurface': ray['originNearSurface'],
        'worldElevation': z,
        'selectedRuntimeElevation': layer.elevation,
        'inferredRuntimeElevation':
            runtime.layerForPosition(isAttack: true, position: start).elevation,
        'runtimeDistanceMeters': runtimeMeters,
        'referenceDistanceMeters': referenceMeters,
        'differenceMeters': runtimeMeters - referenceMeters,
        'objectIndex': ray['objectIndex'],
      });
    }
    final eligible = results.where((r) =>
        r['insideRuntimeFootprint'] == true && r['originNearSurface'] != true);
    final output = {
      'schemaVersion': 1,
      'status':
          'provisional-comparison-requires-registration-and-material-review',
      'certified': false,
      'referenceFile': sourcePath,
      'fingerprints': fingerprints,
      'referenceSha256': source['referenceSha256'],
      'map': map.name,
      'summary': {
        'rays': results.length,
        'eligibleRays': eligible.length,
        'disagreementsOverHalfMeter': eligible
            .where((r) => (r['differenceMeters'] as double).abs() > 0.5)
            .length,
        'disagreementsOverTwoMeters': eligible
            .where((r) => (r['differenceMeters'] as double).abs() > 2)
            .length,
      },
      'rays': results,
    };
    final file = File('build/vision-audit/${map.name}-world-comparison.json');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(output));
    // A completed comparison is not a passing accuracy score.
    // ignore: avoid_print
    print(jsonEncode(output['summary']));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
