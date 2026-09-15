import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/vision_geometry.dart';
import 'package:icarus/view_cone/vision_world_index.dart';
import 'package:icarus/view_cone/vision_world_projection.dart';

void main() {
  test('anisotropic artwork preserves physical angles and requested centerline',
      () {
    final projection = VisionWorldProjection(
        origin: const Offset(10, 20),
        axisU: const Offset(2, 0),
        axisV: const Offset(0, 1));
    final metric = VisionGeometryLayer(
        elevation: 175,
        segments: const [],
        worldIndex: VisionWorldIndex(const []));
    VisionGeometryLayer layer(VisionWorldProjection transform) =>
        VisionGeometryLayer(
            elevation: 175,
            segments: const [],
            metricLayer: metric,
            worldProjection: transform);
    for (final facing in [0.0, math.pi / 4, math.pi / 2]) {
      final physicalDirection =
          projection.vectorToMeters(Offset(math.cos(facing), math.sin(facing)));
      final physicalFacing =
          math.atan2(physicalDirection.dy, physicalDirection.dx);
      final polygon = VisionPolygon.compute(
          layer: layer(projection),
          origin: projection.origin,
          facingAngle: facing,
          coneAngle: math.pi / 2,
          range: 20);
      final expectedCenter =
          projection.origin + Offset(math.cos(facing), math.sin(facing)) * 20;
      expect(polygon.any((p) => (p - expectedCenter).distance < 1e-9), isTrue);
      for (final endpoint in [polygon[1], polygon.last]) {
        final meters = projection.toMeters(endpoint);
        final relativeAngle =
            (math.atan2(meters.dy, meters.dx) - physicalFacing).abs();
        expect(relativeAngle, closeTo(math.pi / 4, 1e-9));
        expect(meters.distance, closeTo(20 * physicalDirection.distance, 1e-9));
      }
      final defense = projection.defense;
      final mirrored = VisionPolygon.compute(
          layer: layer(defense),
          origin: defense.origin,
          facingAngle: facing + math.pi,
          coneAngle: math.pi / 2,
          range: 20);
      expect(mirrored.length, polygon.length);
      for (var i = 0; i < polygon.length; i++) {
        expect(
            (mirrored[i] -
                    Offset(
                        1000 * (16 / 9) - polygon[i].dx, 1000 - polygon[i].dy))
                .distance,
            lessThan(1e-9));
      }
    }
  });

  test('uniform projection matches the existing screen-space cone', () {
    final projection = VisionWorldProjection(
        origin: Offset.zero,
        axisU: const Offset(2, 0),
        axisV: const Offset(0, 2));
    final metricSegments = [
      VisionSegment(const Offset(4, -10), const Offset(4, 10))
    ];
    final segments = [
      for (final s in metricSegments)
        VisionSegment(projection.toCanvas(s.start), projection.toCanvas(s.end))
    ];
    final source = VisionGeometryLayer(elevation: 175, segments: segments);
    final transformed = VisionGeometryLayer(
        elevation: 175,
        segments: segments,
        worldProjection: projection,
        metricLayer: VisionGeometryLayer(
            elevation: 175,
            segments: metricSegments,
            worldIndex: VisionWorldIndex(metricSegments)));
    List<Offset> cone(VisionGeometryLayer layer) => VisionPolygon.compute(
        layer: layer,
        origin: Offset.zero,
        facingAngle: .1,
        coneAngle: math.pi / 2,
        range: 20,
        surfaceClearance: .25);
    final expected = cone(source), actual = cone(transformed);
    expect(actual.length, expected.length);
    for (var i = 0; i < actual.length; i++) {
      expect((actual[i] - expected[i]).distance, lessThan(1e-9));
    }
  });
}
