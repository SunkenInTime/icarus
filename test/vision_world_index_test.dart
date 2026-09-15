import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/vision_geometry.dart';
import 'package:icarus/view_cone/vision_world_index.dart';
import 'package:icarus/view_cone/vision_world_segments.dart';

void main() {
  test('a long wall near the observer keeps its background silhouette', () {
    final edges = [
      VisionSegment(const Offset(-22.5, .25), const Offset(-.5, .25)),
      VisionSegment(const Offset(-.5, -5), const Offset(-.5, .25)),
      VisionSegment(const Offset(-20, 4), const Offset(20, 4)),
    ];
    final index = VisionWorldIndex(edges, planarized: true);
    final angle = math.atan2(.25, -.5) - .015;
    final direction = Offset(math.cos(angle), math.sin(angle));
    final polygon = VisionPolygon.compute(
      layer:
          VisionGeometryLayer(elevation: 0, segments: edges, worldIndex: index),
      origin: Offset.zero,
      facingAngle: 0,
      coneAngle: 2 * math.pi,
      range: 65,
    );
    final boundary = VisionWorldIndex([
      for (var i = 1; i + 1 < polygon.length; i++)
        VisionSegment(polygon[i], polygon[i + 1]),
    ]);
    expect(
        boundary.nearestHit(
            origin: Offset.zero, direction: direction, range: 65),
        closeTo(
            index.nearestHit(
                origin: Offset.zero, direction: direction, range: 65)!,
            1e-7));
  });

  test(
      'world polygons preserve the background immediately beside a near corner',
      () {
    final edges = [
      VisionSegment(const Offset(-.5, -1), const Offset(1, -1)),
      VisionSegment(const Offset(-10, -1.2), const Offset(10, -1.2)),
    ];
    final index = VisionWorldIndex(edges, planarized: true);
    final angle = math.atan2(-1, -.5) - .000001;
    final direction = Offset(math.cos(angle), math.sin(angle));
    final polygon = VisionPolygon.compute(
      layer:
          VisionGeometryLayer(elevation: 0, segments: edges, worldIndex: index),
      origin: Offset.zero,
      facingAngle: 0,
      coneAngle: 2 * math.pi,
      range: 65,
    );
    final boundary = VisionWorldIndex([
      for (var i = 1; i + 1 < polygon.length; i++)
        VisionSegment(polygon[i], polygon[i + 1]),
    ]);
    expect(
        boundary.nearestHit(
            origin: Offset.zero, direction: direction, range: 65),
        closeTo(
            index.nearestHit(
                origin: Offset.zero, direction: direction, range: 65)!,
            1e-7));
  });

  test(
      'occlusion seeds preserve an opening narrower than their angular spacing',
      () {
    final edges = [
      VisionSegment(const Offset(5, -5), const Offset(5, .0045)),
      VisionSegment(const Offset(5, .0055), const Offset(5, 5)),
      VisionSegment(const Offset(10, -5), const Offset(10, 5)),
    ];
    final direction = const Offset(10, .01) / const Offset(10, .01).distance;
    for (final clearance in [0.0, .002]) {
      final polygon = VisionPolygon.compute(
        layer: VisionGeometryLayer(
            elevation: 0,
            segments: edges,
            worldIndex: VisionWorldIndex(edges, planarized: true)),
        origin: Offset.zero,
        facingAngle: 0,
        coneAngle: .03,
        range: 20,
        surfaceClearance: clearance,
      );
      final boundary = VisionWorldIndex([
        for (var i = 1; i + 1 < polygon.length; i++)
          VisionSegment(polygon[i], polygon[i + 1])
      ]);
      expect(
          boundary.nearestHit(
              origin: Offset.zero, direction: direction, range: 20),
          closeTo(const Offset(10, .01).distance - clearance, 1e-7));
    }
  });

  test('cone pruning keeps crossing walls with both endpoints outside', () {
    final crossing = VisionSegment(const Offset(2, -10), const Offset(2, 10));
    final behind = VisionSegment(const Offset(-2, -1), const Offset(-2, 1));
    final boundary = VisionSegment(const Offset(1, 1), const Offset(3, 3));
    final index = VisionWorldIndex([crossing, behind, boundary]);
    expect(
        index.queryCone(
            origin: Offset.zero,
            facingAngle: 0,
            coneAngle: math.pi / 2,
            range: 20),
        unorderedEquals([crossing, boundary]));
    expect(
        index.queryCone(
            origin: Offset.zero,
            facingAngle: 0,
            coneAngle: math.pi * 2,
            range: 20),
        unorderedEquals([crossing, behind, boundary]));
  });

  test('packed world edges preserve exact ray hits and bounds queries', () {
    final random = math.Random(18761);
    final vertices = Int32List.fromList(
        [for (var i = 0; i < 1200; i++) random.nextInt(20000) - 10000]);
    final packed = VisionWorldSegments.fromQuantized(
      vertices: vertices,
      edges: Int32List.fromList(List.generate(600, (index) => index)),
      layerEdges: Int32List.fromList(List.generate(300, (index) => index)),
      coordinateScale: 1000,
      uvUnitsPerMeter: const Offset(.5, 2),
    );
    final ordinary = List<VisionSegment>.of(packed);
    final typedIndex = VisionWorldIndex(packed, spatiallyOrdered: true);
    final originalIndex = VisionWorldIndex(ordinary);
    for (var i = 0; i < 1000; i++) {
      final origin =
          Offset(random.nextDouble() * 60 - 30, random.nextDouble() * 30 - 15);
      final angle = random.nextDouble() * math.pi * 2;
      final direction = Offset(math.cos(angle), math.sin(angle));
      final expected = originalIndex.nearestHit(
          origin: origin, direction: direction, range: 40);
      final actual = typedIndex.nearestHit(
          origin: origin, direction: direction, range: 40);
      expect(actual, expected == null ? isNull : closeTo(expected, 1e-12));
      if (i % 20 == 0) {
        final bounds = Rect.fromCircle(center: origin, radius: 3);
        expect(typedIndex.queryBounds(bounds),
            unorderedEquals(originalIndex.queryBounds(bounds)));
      }
    }
    expect(() => packed.clear(), throwsUnsupportedError);
  });

  test('collinear rays stop at forward endpoints and overlapping blockers', () {
    for (final segment in [
      VisionSegment.unthickened(const Offset(5, 0), const Offset(10, 0)),
      VisionSegment.unthickened(const Offset(10, 0), const Offset(5, 0)),
    ]) {
      final index = VisionWorldIndex([segment]);
      double? hit(Offset origin, Offset direction) =>
          index.nearestHit(origin: origin, direction: direction, range: 20);
      expect(hit(Offset.zero, const Offset(1, 0)), 5);
      expect(hit(const Offset(7, 0), const Offset(1, 0)), 0);
      expect(hit(const Offset(15, 0), const Offset(-1, 0)), 5);
      expect(hit(const Offset(15, 0), const Offset(1, 0)), isNull);
      expect(hit(const Offset(0, .01), const Offset(1, 0)), isNull);
    }
  });

  test('surface clearance applies after the nearest wall is selected', () {
    final segments = [
      // Its near endpoint makes this farther center-ray hit get visited first.
      VisionSegment(const Offset(1, -1), const Offset(9, 1)),
      VisionSegment(const Offset(4.9, -1), const Offset(4.9, 1)),
    ];
    for (final index in [null, VisionWorldIndex(segments)]) {
      final polygon = VisionPolygon.compute(
        layer: VisionGeometryLayer(
            elevation: 0, segments: segments, worldIndex: index),
        origin: Offset.zero,
        facingAngle: 0,
        coneAngle: .01,
        range: 10,
        surfaceClearance: .25,
      );
      expect(polygon.any((p) => (p - const Offset(4.65, 0)).distance < 1e-9),
          isTrue);
    }
  });

  test('visible endpoint pruning preserves planarized world boundaries', () {
    final segments = <VisionSegment>[];
    void box(double x, double y, double width, double height) {
      final points = [
        Offset(x, y),
        Offset(x + width, y),
        Offset(x + width, y + height),
        Offset(x, y + height)
      ];
      for (var i = 0; i < 4; i++) {
        segments.add(VisionSegment(points[i], points[(i + 1) % 4]));
      }
    }

    box(-400, -400, 800, 800);
    for (var x = -300.0; x <= 300; x += 60) {
      for (var y = -300.0; y <= 300; y += 60) {
        box(x, y, 20, 20);
      }
    }
    final index = VisionWorldIndex(segments, planarized: true);
    final layer = VisionGeometryLayer(
        elevation: 0, segments: segments, worldIndex: index);
    final random = math.Random(1207);
    for (var test = 0; test < 12; test++) {
      final origin = Offset(
          random.nextDouble() * 400 - 200, random.nextDouble() * 400 - 200);
      final polygon = VisionPolygon.compute(
          layer: layer,
          origin: origin,
          facingAngle: 0,
          coneAngle: math.pi * 2,
          range: 2000);
      final unpruned = VisionPolygon.compute(
          layer: VisionGeometryLayer(
              elevation: 0,
              segments: segments,
              worldIndex: VisionWorldIndex(segments)),
          origin: origin,
          facingAngle: 0,
          coneAngle: math.pi * 2,
          range: 2000);
      for (var i = 0; i < 360; i++) {
        final angle = (i + .173) * math.pi / 180;
        final direction = Offset(math.cos(angle), math.sin(angle));
        final expected = index.nearestHit(
            origin: origin, direction: direction, range: 2000)!;
        double polygonHit(List<Offset> points) {
          var distanceToPolygon = double.infinity;
          for (var p = 2; p < points.length; p++) {
            final start = points[p - 1], edge = points[p] - start;
            final denominator = visionCross(direction, edge);
            if (denominator.abs() < 1e-12) continue;
            final distance = visionCross(start - origin, edge) / denominator;
            final t = visionCross(start - origin, direction) / denominator;
            if (distance > 0 && t >= 0 && t <= 1) {
              distanceToPolygon = math.min(distanceToPolygon, distance);
            }
          }
          return distanceToPolygon;
        }

        final actual = polygonHit(polygon);
        // The legacy path perturbs corners by 1e-5 radians. Baked planarized
        // geometry narrows that strip to 1e-8, preserving near-corner sightlines.
        final cornerDistances =
            segments.expand((s) => [s.start, s.end]).map((p) {
          final delta = p - origin;
          final difference =
              (math.atan2(delta.dy, delta.dx) - angle + math.pi) %
                      (math.pi * 2) -
                  math.pi;
          return difference.abs();
        });
        if (!cornerDistances.any((distance) => distance <= .000011)) {
          expect(actual, closeTo(polygonHit(unpruned), 1e-5));
        }
        if (!cornerDistances.any((distance) => distance <= .000000011)) {
          expect(actual, closeTo(expected, 1e-5));
        }
      }
    }
  });

  test('indexed polygons preserve exact brute force hits and wall events', () {
    final random = math.Random(927);
    final segments = [
      for (var i = 0; i < 500; i++)
        VisionSegment(
          Offset(
              random.nextDouble() * 300 - 150, random.nextDouble() * 300 - 150),
          Offset(
              random.nextDouble() * 300 - 150, random.nextDouble() * 300 - 150),
        ),
      // Axis-parallel and degenerate AABBs must be visited too.
      VisionSegment(const Offset(7, -20), const Offset(7, 20)),
      VisionSegment(const Offset(-20, -7), const Offset(20, -7)),
    ];
    final source = VisionGeometryLayer(elevation: 0, segments: segments);
    final indexed = VisionGeometryLayer(
      elevation: 0,
      segments: segments,
      worldIndex: VisionWorldIndex(segments),
    );
    final ordered = VisionGeometryLayer(
      elevation: 0,
      segments: segments,
      worldIndex: VisionWorldIndex(segments, spatiallyOrdered: true),
    );
    for (var i = 0; i < 60; i++) {
      final origin = Offset(
          random.nextDouble() * 100 - 50, random.nextDouble() * 100 - 50);
      final facing =
          i < 4 ? i * math.pi / 2 : random.nextDouble() * math.pi * 2;
      final angle = random.nextDouble() * math.pi + 0.01;
      final range = random.nextDouble() * 200 + 5;
      final clearance = i.isEven ? 0.0 : 0.25;
      List<Offset> compute(VisionGeometryLayer layer) => VisionPolygon.compute(
            layer: layer,
            origin: origin,
            facingAngle: facing,
            coneAngle: angle,
            range: range,
            surfaceClearance: clearance,
          );
      final expected = compute(source);
      final actual = compute(indexed);
      final preordered = compute(ordered);
      expect(actual.length, expected.length);
      expect(preordered.length, expected.length);
      for (var j = 0; j < expected.length; j++) {
        expect((actual[j] - expected[j]).distance, lessThan(1e-7));
        expect((preordered[j] - expected[j]).distance, lessThan(1e-7));
      }
      expect(identical(actual, compute(indexed)), isTrue,
          reason: 'An unchanged cone should reuse the exact polygon.');
      expect(() => actual.add(Offset.zero), throwsUnsupportedError);
    }
  });

  test('range query retains segments touching a query boundary', () {
    final segments = [
      VisionSegment(const Offset(5, -5), const Offset(5, 5)),
      VisionSegment(const Offset(-5, 5), const Offset(5, 5)),
      VisionSegment(const Offset(6, -5), const Offset(6, 5)),
    ];
    final index = VisionWorldIndex(segments);
    expect(index.queryBounds(const Rect.fromLTRB(-5, -5, 5, 5)),
        unorderedEquals(segments.take(2)));
    expect(
        index.nearestHit(
            origin: Offset.zero, direction: const Offset(1, 0), range: 20),
        5);
    expect(
        index.nearestHit(
            origin: Offset.zero, direction: const Offset(-1, 0), range: 20),
        isNull);
  });

  test('world index rejects authored stroke collisions', () {
    expect(
        () => VisionWorldIndex([
              VisionSegment(const Offset(0, 0), const Offset(1, 0),
                  collisionRadius: 0.2),
            ]),
        throwsArgumentError);
  });
}
