import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/view_cone/vision_geometry.dart';
import 'package:icarus/view_cone/vision_world_index.dart';

class _LocalWorldBundle extends CachingAssetBundle {
  _LocalWorldBundle(this.directory);
  final String directory;
  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(
      await File('$directory/${key.split('/').last}').readAsBytes());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('baked world visibility timing', () async {
    const directory = String.fromEnvironment('WORLD_DIRECTORY');
    const mapName = String.fromEnvironment('WORLD_MAP', defaultValue: 'split');
    const range = int.fromEnvironment('WORLD_RANGE', defaultValue: 361);
    const binary = bool.fromEnvironment('WORLD_BINARY');
    final map = MapValue.values.byName(mapName);
    final watch = Stopwatch()..start();
    final geometry = await loadWorldViewConeGeometry(map,
        bundle: _LocalWorldBundle(directory), binary: binary);
    final loadMicros = watch.elapsedMicroseconds;
    final plane = geometry.layerFor(isAttack: true);
    // Both index modes use identical segments. The baked flag asserts that
    // intersections were split offline before hidden events may be discarded.
    final indexed = VisionGeometryLayer(
        elevation: plane.elevation,
        segments: plane.segments,
        worldIndex: VisionWorldIndex(plane.segments, planarized: true));
    final unpruned = VisionGeometryLayer(
        elevation: plane.elevation,
        segments: plane.segments,
        worldIndex: VisionWorldIndex(plane.segments));
    final navigation = geometry.navigationGeometry!;
    final candidates = navigation.vertices
        .where((v) =>
            (v.floorHeight + geometry.observerHeight - plane.elevation).abs() <
            1)
        .toList();
    expect(candidates, isNotEmpty);
    final samples = <Map<String, dynamic>>[];
    for (var i = 0; i < 12; i++) {
      final origin =
          candidates[(candidates.length * (i + .5) / 12).floor()].position;
      final facing = i * math.pi / 6;
      List<Offset> cone(VisionGeometryLayer layer) => VisionPolygon.compute(
          layer: layer,
          origin: origin,
          facingAngle: facing,
          coneAngle: math.pi * 103 / 180,
          range: range.toDouble());
      watch.reset();
      final original = cone(unpruned);
      final fullMicros = watch.elapsedMicroseconds;
      watch.reset();
      final polygon = cone(indexed);
      final prunedMicros = watch.elapsedMicroseconds;
      double radialHit(List<Offset> points, Offset direction) {
        var nearest = double.infinity;
        for (var p = 2; p < points.length; p++) {
          final start = points[p - 1], edge = points[p] - start;
          final denominator = visionCross(direction, edge);
          if (denominator.abs() < 1e-12) continue;
          final hit = visionCross(start - origin, edge) / denominator;
          final t = visionCross(start - origin, direction) / denominator;
          if (hit >= 0 && t >= 0 && t <= 1) nearest = math.min(nearest, hit);
        }
        return nearest;
      }

      var maximumDifference = 0.0;
      for (var ray = 0; ray < 180; ray++) {
        final angle = facing + (ray / 179 - .5) * math.pi * 102.9 / 180;
        final direction = Offset(math.cos(angle), math.sin(angle));
        final difference =
            (radialHit(original, direction) - radialHit(polygon, direction))
                .abs();
        expect(difference.isFinite, isTrue);
        maximumDifference = math.max(maximumDifference, difference);
      }
      // Open range arcs retain the renderer's 2-degree maximum chord step.
      expect(maximumDifference,
          lessThan(range * (1 - math.cos(math.pi / 180)) + .0001));
      watch.reset();
      for (var call = 0; call < 1000; call++) {
        cone(indexed);
      }
      final stationaryMicros = watch.elapsedMicroseconds / 1000;
      samples.add({
        'origin': [origin.dx, origin.dy],
        'unprunedMicros': fullMicros,
        'prunedMicros': prunedMicros,
        'stationaryMicros': stationaryMicros,
        'unprunedVertices': original.length,
        'prunedVertices': polygon.length,
        'maximumBoundaryDifferenceCanvasUnits': maximumDifference,
      });
    }
    final result = {
      'map': mapName,
      'source': directory,
      'binary': binary,
      'processRssBytesAfterSamples': ProcessInfo.currentRss,
      'segments': plane.segments.length,
      'range': range,
      'loadMicros': loadMicros,
      'samples': samples,
      'profile': 'flutter-test JIT, not release device performance'
    };
    final file = File('build/vision-audit/$mapName-baked-benchmark.json');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(result));
    // ignore: avoid_print
    print(jsonEncode(result));
  });
}
