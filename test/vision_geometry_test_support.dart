import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/svg_vision_boundary.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

Set<String> segmentKeys(Iterable<VisionSegment> segments) => {
      for (final segment in segments) visionSegmentKey(segment),
    };

void expectExactSvgRuntime({
  required List<VisionGeometryLayer> layers,
  required VisionBoundary boundary,
  required String reason,
}) {
  final allowedKeys = segmentKeys(
    boundary.collisionGroups.expand((group) => group.collisionSegments),
  );
  for (final group in boundary.collisionGroups) {
    final exactPathKeys = <String>{
      for (final path in group.paths)
        for (var index = 1; index < path.length; index += 1)
          if ((path[index] - path[index - 1]).distanceSquared > 1e-9)
            visionSegmentKey(VisionSegment(path[index - 1], path[index])),
    };
    expect(
      segmentKeys(group.segments),
      unorderedEquals(exactPathKeys),
      reason: '$reason ${group.id} synthesized a cross-path edge',
    );
  }
  for (final layer in layers) {
    final runtimeKeys = segmentKeys(layer.segments);
    final groupedKeys = segmentKeys(
      layer.collisionGroups.expand((group) => group.collisionSegments),
    );

    expect(layer.sourceSegments, isEmpty, reason: '$reason source geometry');
    expect(layer.riotSegments, isEmpty, reason: '$reason Riot leakage');
    expect(
      runtimeKeys,
      unorderedEquals(groupedKeys),
      reason: '$reason elevation ${layer.elevation} group union',
    );
    expect(
      runtimeKeys.every(allowedKeys.contains),
      isTrue,
      reason: '$reason elevation ${layer.elevation} must use exact SVG keys',
    );
    for (final group in layer.collisionGroups) {
      expect(
        group.activeInLayer(layer.layerIndex),
        isTrue,
        reason: '$reason ${group.id} has an inconsistent layer mask',
      );
      expect(
        runtimeKeys,
        containsAll(segmentKeys(group.collisionSegments)),
        reason: '$reason ${group.id} is not atomically present',
      );
    }
  }
}

VisionCollisionGroup groupNearBounds(
  VisionBoundary boundary,
  Rect expected, {
  double tolerance = 1,
}) {
  bool near(double actual, double target) =>
      (actual - target).abs() <= tolerance;
  return boundary.collisionGroups.singleWhere(
    (group) =>
        near(group.bounds.left, expected.left) &&
        near(group.bounds.top, expected.top) &&
        near(group.bounds.right, expected.right) &&
        near(group.bounds.bottom, expected.bottom),
  );
}

VisionGeometryMap oneLayerGeometry(MapValue map) =>
    VisionGeometryMap.fromCompactJson(
      map,
      <String, dynamic>{
        'version': 2,
        'map': Maps.mapNames[map],
        'coordinateScale': 65536,
        'defaultElevation': 0,
        'observerHeight': 100,
        'heightSamples': <int>[],
        'layers': <Map<String, dynamic>>[
          <String, dynamic>{
            'elevation': 0,
            'vertices': <int>[],
            'edges': <int>[],
          },
        ],
      },
    );

VisionGeometryMap twoLayerAscentGeometry() => VisionGeometryMap.fromCompactJson(
      MapValue.ascent,
      <String, dynamic>{
        'version': 2,
        'map': 'ascent',
        'coordinateScale': 65536,
        'defaultElevation': 0,
        'observerHeight': 100,
        'heightSamples': <int>[],
        'layers': <Map<String, dynamic>>[
          <String, dynamic>{
            'elevation': 0,
            'vertices': <int>[],
            'edges': <int>[],
          },
          <String, dynamic>{
            'elevation': 500,
            'vertices': <int>[],
            'edges': <int>[],
          },
        ],
      },
    );

VisionGeometryMap twoLayerBreezeGeometry({
  required List<int> heightSamples,
}) =>
    VisionGeometryMap.fromCompactJson(
      MapValue.breeze,
      <String, dynamic>{
        'version': 2,
        'map': 'breeze',
        'coordinateScale': 65536,
        'defaultElevation': 100,
        'observerHeight': 100,
        'heightSamples': heightSamples,
        'layers': <Map<String, dynamic>>[
          <String, dynamic>{
            'elevation': 100,
            'vertices': <int>[],
            'edges': <int>[],
          },
          <String, dynamic>{
            'elevation': 500,
            'vertices': <int>[],
            'edges': <int>[],
          },
        ],
      },
    );

List<int> breezeHeightSample(double svgX, double svgY, int elevation) {
  const leftPadding = 14.878981;
  const topPadding = 14.878981;
  const paddedWidth = 447 + 14.878981 + 14.878981;
  const paddedHeight = 473 + 14.878981 + 23.248408;
  return <int>[
    (((svgX + leftPadding) / paddedWidth) * 65536).round(),
    (((svgY + topPadding) / paddedHeight) * 65536).round(),
    elevation,
  ];
}

VisionBoundary overrideTestBoundary() {
  const source = '''
<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <path fill="#271406" d="M5 5H95V95H5Z"/>
  <path stroke="#B27C40" d="M30 30H40V40H30Z"/>
</svg>
''';
  return SvgVisionBoundary.parse(map: MapValue.ascent, source: source);
}

VisionCollisionGroup classifiedGroup({
  required List<Offset> points,
  required int observerExclusionLayerMask,
}) =>
    VisionCollisionGroup.geometry(
      points: points,
      kind: VisionCollisionKind.structuralObstacle,
      isClosed: true,
    ).classify(
      layerMask: 1,
      evidenceLayerMask: 1,
      navigationLayerMask: observerExclusionLayerMask,
      observerExclusionLayerMask: observerExclusionLayerMask,
      coverageByLayer: const [1],
      confidence: VisionCollisionConfidence.matched,
      overrideApplied: false,
    );

List<VisionSegment> deduplicateTestSegments(
  Iterable<VisionSegment> segments,
) {
  final keys = <String>{};
  return <VisionSegment>[
    for (final segment in segments)
      if (keys.add(visionSegmentKey(segment))) segment,
  ];
}

bool segmentBoundsOverlap(VisionSegment segment, Rect bounds) =>
    segment.maxX >= bounds.left &&
    segment.minX <= bounds.right &&
    segment.maxY >= bounds.top &&
    segment.minY <= bounds.bottom;

bool segmentBoundsInside(VisionSegment segment, Rect bounds) =>
    segment.minX >= bounds.left &&
    segment.maxX <= bounds.right &&
    segment.minY >= bounds.top &&
    segment.maxY <= bounds.bottom;

bool rectNear(
  Rect actual,
  Rect expected, {
  required double tolerance,
}) =>
    (actual.left - expected.left).abs() <= tolerance &&
    (actual.top - expected.top).abs() <= tolerance &&
    (actual.right - expected.right).abs() <= tolerance &&
    (actual.bottom - expected.bottom).abs() <= tolerance;

double centerRayDistance({
  required VisionGeometryLayer layer,
  required Offset origin,
  required double facingAngle,
  required double range,
}) =>
    (centerRayPoint(
              layer: layer,
              origin: origin,
              facingAngle: facingAngle,
              range: range,
            ) -
            origin)
        .distance;

Offset centerRayPoint({
  required VisionGeometryLayer layer,
  required Offset origin,
  required double facingAngle,
  required double range,
}) {
  final polygon = VisionPolygon.compute(
    layer: layer,
    origin: origin,
    facingAngle: facingAngle,
    coneAngle: math.pi / 90,
    range: range,
  );
  double angularError(Offset point) {
    final delta = point - origin;
    var error = math.atan2(delta.dy, delta.dx) - facingAngle;
    while (error > math.pi) error -= math.pi * 2;
    while (error < -math.pi) error += math.pi * 2;
    return error.abs();
  }

  final centerPoint = polygon.skip(1).reduce(
        (best, point) =>
            angularError(point) < angularError(best) ? point : best,
      );
  expect(angularError(centerPoint), lessThan(1e-8));
  return centerPoint;
}

void expectOnVisibleStroke(
  Offset point,
  Iterable<VisionSegment> segments,
) {
  final error = segments
      .where((segment) => segment.collisionRadius > 0)
      .map(
        (segment) =>
            (math.sqrt(visionDistanceSquaredToSegment(point, segment)) -
                    segment.collisionRadius)
                .abs(),
      )
      .reduce(math.min);
  expect(error, lessThan(0.001));
}
