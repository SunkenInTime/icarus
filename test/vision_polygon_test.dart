import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/svg_vision_boundary.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

import 'vision_geometry_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VisionPolygon', () {
    test('clips the center of a cone at the nearest wall', () {
      final layer = VisionGeometryLayer(
        elevation: 0,
        segments: [VisionSegment(const Offset(5, -10), const Offset(5, 10))],
      );

      final polygon = VisionPolygon.compute(
        layer: layer,
        origin: Offset.zero,
        facingAngle: 0,
        coneAngle: math.pi / 2,
        range: 10,
      );
      final centerPoint = polygon.skip(1).reduce(
            (best, point) => point.dy.abs() < best.dy.abs() ? point : best,
          );

      expect(centerPoint.dx, closeTo(5, 0.001));
      expect(centerPoint.dy, closeTo(0, 0.001));
    });

    test('clips to the visible near edge of a thick wall stroke', () {
      final wall = VisionSegment(
        const Offset(5, -10),
        const Offset(5, 10),
        collisionRadius: 1.25,
      );
      final layer = VisionGeometryLayer(elevation: 0, segments: [wall]);

      final hit = centerRayPoint(
        layer: layer,
        origin: Offset.zero,
        facingAngle: 0,
        range: 20,
      );

      expect(hit, const Offset(3.75, 0));
      expectOnVisibleStroke(hit, [wall]);

      final angledHit = centerRayPoint(
        layer: layer,
        origin: Offset.zero,
        facingAngle: math.atan2(4, 5),
        range: 20,
      );
      expect(angledHit.dx, closeTo(3.75, 0.000001));
      expect(angledHit.dy, closeTo(3, 0.000001));
      expectOnVisibleStroke(angledHit, [wall]);
    });

    test('emits thick wall corners instead of cutting through the stroke', () {
      final wall = VisionSegment(
        const Offset(5, -2),
        const Offset(5, 2),
        collisionRadius: 1,
      );
      final polygon = VisionPolygon.compute(
        layer: VisionGeometryLayer(elevation: 0, segments: [wall]),
        origin: Offset.zero,
        facingAngle: 0,
        coneAngle: math.pi / 2,
        range: 10,
      );

      for (final visibleCorner in const [Offset(4, -2), Offset(4, 2)]) {
        expect(
          polygon,
          contains(
            predicate<Offset>(
              (point) => (point - visibleCorner).distanceSquared < 1e-8,
              'the visible stroke corner $visibleCorner',
            ),
          ),
        );
      }
    });

    test('clips at the rendered miter edge where thick wall segments turn', () {
      final group = VisionCollisionGroup.geometry(
        points: const [
          Offset(-5, 0),
          Offset.zero,
          Offset(0, 5),
        ],
        kind: VisionCollisionKind.structuralChain,
        isClosed: false,
        collisionRadius: 1,
      );
      final layer = VisionGeometryLayer(
        elevation: 0,
        segments: group.collisionSegments,
      );

      final hit = centerRayPoint(
        layer: layer,
        origin: const Offset(5, -0.5),
        facingAngle: math.pi,
        range: 10,
      );

      expect(hit.dx, closeTo(1, 0.000001));
      expect(hit.dy, closeTo(-0.5, 0.000001));
    });

    test('uses the range arc when no wall blocks a ray', () {
      const origin = Offset(12, 18);
      const range = 30.0;
      final polygon = VisionPolygon.compute(
        layer: const VisionGeometryLayer(elevation: 0, segments: []),
        origin: origin,
        facingAngle: -math.pi / 2,
        coneAngle: math.pi / 3,
        range: range,
      );

      expect(polygon.length, greaterThan(20));
      for (final point in polygon.skip(1)) {
        expect((point - origin).distance, closeTo(range, 1e-8));
      }
    });

    test('excludes a passable closed group around its observer', () {
      final group = VisionCollisionGroup.geometry(
        points: const [
          Offset(5, -2),
          Offset(10, -2),
          Offset(10, 2),
          Offset(5, 2),
          Offset(5, -2),
        ],
        kind: VisionCollisionKind.structuralObstacle,
        isClosed: true,
      ).classify(
        layerMask: 1,
        evidenceLayerMask: 1,
        navigationLayerMask: 1,
        observerExclusionLayerMask: 1,
        coverageByLayer: const [1],
        confidence: VisionCollisionConfidence.matched,
        overrideApplied: false,
      );
      final layer = VisionGeometryLayer(
        elevation: 0,
        segments: group.segments,
        collisionGroups: [group],
        layerIndex: 0,
      );

      expect(
        centerRayDistance(
          layer: layer,
          origin: const Offset(7.5, 0),
          facingAngle: 0,
          range: 20,
        ),
        closeTo(20, 1e-8),
      );
      expect(
        centerRayDistance(
          layer: layer,
          origin: Offset.zero,
          facingAngle: 0,
          range: 20,
        ),
        closeTo(5, 0.001),
      );
    });

    test('retains a shared edge owned by a non-excluded group', () {
      final excluded = classifiedGroup(
        points: const [
          Offset(0, 0),
          Offset(10, 0),
          Offset(10, 10),
          Offset(0, 10),
          Offset(0, 0),
        ],
        observerExclusionLayerMask: 1,
      );
      final retained = classifiedGroup(
        points: const [
          Offset(10, 0),
          Offset(20, 0),
          Offset(20, 10),
          Offset(10, 10),
          Offset(10, 0),
        ],
        observerExclusionLayerMask: 0,
      );
      final segments = deduplicateTestSegments([
        ...excluded.segments,
        ...retained.segments,
      ]);
      final layer = VisionGeometryLayer(
        elevation: 0,
        segments: segments,
        collisionGroups: [excluded, retained],
        layerIndex: 0,
        segmentIndex: VisionSegmentIndex(segments),
      );
      final available = segmentKeys(
        layer.segmentsForObserver(const Offset(5, 5), 100),
      );
      final shared = excluded.segments.singleWhere(
        (segment) => segment.start.dx == 10 && segment.end.dx == 10,
      );
      final excludedOnly = excluded.segments.singleWhere(
        (segment) => segment.start.dx == 0 && segment.end.dx == 0,
      );

      expect(available, contains(visionSegmentKey(shared)));
      expect(available, isNot(contains(visionSegmentKey(excludedOnly))));
    });

    test('nested passability never permits an observer outside the footprint',
        () {
      final outer = VisionCollisionGroup.geometry(
        points: const [
          Offset(0, 0),
          Offset(10, 0),
          Offset(10, 10),
          Offset(0, 10),
          Offset(0, 0),
        ],
        kind: VisionCollisionKind.maskBoundary,
        isClosed: true,
        isOuterBoundary: true,
      );
      final nested = VisionCollisionGroup.geometry(
        points: const [
          Offset(20, 20),
          Offset(30, 20),
          Offset(30, 30),
          Offset(20, 30),
          Offset(20, 20),
        ],
        kind: VisionCollisionKind.maskBoundary,
        isClosed: true,
        nestingDepth: 1,
      ).classify(
        layerMask: 1,
        evidenceLayerMask: 0,
        navigationLayerMask: 1,
        observerExclusionLayerMask: 1,
        coverageByLayer: const [0],
        confidence: VisionCollisionConfidence.unmatchedDefault,
        overrideApplied: false,
      );
      final boundary = VisionBoundary(
        segments: [...outer.segments, ...nested.segments],
        maskSegments: outer.segments,
        contours: [outer.points],
        collisionGroups: [outer, nested],
        outerGroupId: outer.id,
        fillRule: VisionFillRule.evenOdd,
      );
      final layer = VisionGeometryLayer(
        elevation: 0,
        segments: [...outer.segments, ...nested.segments],
        boundary: boundary,
        collisionGroups: [outer, nested],
        observerGroups: [nested],
        layerIndex: 0,
      );
      const origin = Offset(25, 25);

      expect(nested.contains(origin), isTrue);
      expect(boundary.containsOuterFootprint(origin), isFalse);
      expect(layer.contains(origin), isFalse);
      expect(
        VisionPolygon.compute(
          layer: layer,
          origin: origin,
          facingAngle: 0,
          coneAngle: math.pi / 2,
          range: 20,
        ),
        [origin],
      );
    });

    test('leaves a real doorway gap open while its flanks block', () {
      final upper = VisionCollisionGroup.geometry(
        points: const [
          Offset(5, -10),
          Offset(10, -10),
          Offset(10, -1),
          Offset(5, -1),
          Offset(5, -10),
        ],
        kind: VisionCollisionKind.structuralObstacle,
        isClosed: true,
      );
      final lower = VisionCollisionGroup.geometry(
        points: const [
          Offset(5, 1),
          Offset(10, 1),
          Offset(10, 10),
          Offset(5, 10),
          Offset(5, 1),
        ],
        kind: VisionCollisionKind.structuralObstacle,
        isClosed: true,
      );
      final layer = VisionGeometryLayer(
        elevation: 0,
        segments: [...upper.segments, ...lower.segments],
      );

      expect(
        centerRayDistance(
          layer: layer,
          origin: Offset.zero,
          facingAngle: 0,
          range: 20,
        ),
        closeTo(20, 1e-8),
      );
      expect(
        centerRayDistance(
          layer: layer,
          origin: Offset.zero,
          facingAngle: math.atan2(2, 5),
          range: 20,
        ),
        closeTo(math.sqrt(29), 0.001),
      );
    });

    test('shared-vertex rays do not leak and are segment-order deterministic',
        () {
      final forward = VisionGeometryLayer(
        elevation: 0,
        segments: [
          VisionSegment(const Offset(5, -8), const Offset(5, 0)),
          VisionSegment(const Offset(5, 0), const Offset(5, 8)),
        ],
      );
      final reversed = VisionGeometryLayer(
        elevation: 0,
        segments: [
          VisionSegment(const Offset(5, 8), const Offset(5, 0)),
          VisionSegment(const Offset(5, 0), const Offset(5, -8)),
        ],
      );
      final first = VisionPolygon.compute(
        layer: forward,
        origin: Offset.zero,
        facingAngle: 0,
        coneAngle: math.pi / 2,
        range: 20,
      );
      final second = VisionPolygon.compute(
        layer: reversed,
        origin: Offset.zero,
        facingAngle: 0,
        coneAngle: math.pi / 2,
        range: 20,
      );

      final nearCorner = first.where(
        (point) => (point.dx - 5).abs() < 0.01 && point.dy.abs() < 0.01,
      );
      expect(nearCorner.length, greaterThanOrEqualTo(2));
      expect(first, hasLength(second.length));
      for (var index = 0; index < first.length; index += 1) {
        expect(second[index].dx, closeTo(first[index].dx, 1e-8));
        expect(second[index].dy, closeTo(first[index].dy, 1e-8));
      }
    });

    test('mirrored side positions and rotations produce symmetric clips', () {
      const worldWidth = 1000 * 16 / 9;
      const attackOrigin = Offset(50, 500);
      const defenseOrigin = Offset(worldWidth - 50, 500);
      final attackLayer = VisionGeometryLayer(
        elevation: 0,
        segments: [
          VisionSegment(const Offset(100, 450), const Offset(100, 550)),
        ],
      );
      final defenseLayer = VisionGeometryLayer(
        elevation: 0,
        segments: [
          VisionSegment(
            const Offset(worldWidth - 100, 550),
            const Offset(worldWidth - 100, 450),
          ),
        ],
      );

      final attack = VisionPolygon.compute(
        layer: attackLayer,
        origin: attackOrigin,
        facingAngle: 0,
        coneAngle: math.pi / 2,
        range: 100,
      );
      final defense = VisionPolygon.compute(
        layer: defenseLayer,
        origin: defenseOrigin,
        facingAngle: math.pi,
        coneAngle: math.pi / 2,
        range: 100,
      );

      expect(defense, hasLength(attack.length));
      for (var index = 0; index < attack.length; index += 1) {
        final mirroredDefense = Offset(
          worldWidth - defense[index].dx,
          1000 - defense[index].dy,
        );
        expect(mirroredDefense.dx, closeTo(attack[index].dx, 1e-8));
        expect(mirroredDefense.dy, closeTo(attack[index].dy, 1e-8));
      }
    });

    test('clips to a square extracted from the rendered SVG', () {
      const source = '''
<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <path fill="#271406" fill-rule="evenodd" d="M10 10H90V90H10Z"/>
</svg>
''';
      final boundary = SvgVisionBoundary.parse(
        map: MapValue.ascent,
        source: source,
      );
      final layer = VisionGeometryLayer(
        elevation: 0,
        segments: boundary.segments,
        boundary: boundary,
      );
      final bounds = boundary.segments.fold<Rect>(
        Rect.fromPoints(
          boundary.segments.first.start,
          boundary.segments.first.end,
        ),
        (rect, segment) => rect.expandToInclude(
          Rect.fromPoints(segment.start, segment.end),
        ),
      );
      final origin = bounds.center;
      final polygon = VisionPolygon.compute(
        layer: layer,
        origin: origin,
        facingAngle: 0,
        coneAngle: math.pi / 2,
        range: bounds.width,
      );
      final centerPoint = polygon.skip(1).reduce(
            (best, point) =>
                (point.dy - origin.dy).abs() < (best.dy - origin.dy).abs()
                    ? point
                    : best,
          );

      expect(boundary.contains(origin), isTrue);
      expect(
        centerPoint.dx,
        closeTo(
          bounds.right - boundary.segments.first.collisionRadius,
          0.001,
        ),
      );
      expect(centerPoint.dy, closeTo(origin.dy, 0.001));
    });

    test('does not paint a cone whose apex is outside the SVG floor mask', () {
      const source = '''
<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <path fill="#271406" d="M10 10H90V90H10Z"/>
</svg>
''';
      final boundary = SvgVisionBoundary.parse(
        map: MapValue.ascent,
        source: source,
      );
      final origin = boundary.segments
          .map((segment) => segment.start)
          .reduce((left, right) => left.dx < right.dx ? left : right)
          .translate(-10, 0);
      final polygon = VisionPolygon.compute(
        layer: VisionGeometryLayer(
          elevation: 0,
          segments: boundary.segments,
          boundary: boundary,
        ),
        origin: origin,
        facingAngle: 0,
        coneAngle: math.pi / 2,
        range: 100,
      );

      expect(boundary.contains(origin), isFalse);
      expect(polygon, [origin]);
    });
  });
}
