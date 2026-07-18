import 'dart:ui';

import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

/// Builds Icarus collision geometry from authored map polygons.
///
/// The reference data uses a normalized canvas. The outer polygon is used
/// as a registration frame so every interior and height-box point receives the
/// same axis-aligned transform into Icarus's rendered tactical-map footprint.
class AuthoredVisionBoundary {
  static VisionBoundary parse({
    required MapValue map,
    required Map<String, dynamic> document,
    required Rect attackTargetBounds,
    bool isDefense = false,
  }) {
    final maps = document['maps'];
    if (document['version'] != 1 || maps is! Map<String, dynamic>) {
      throw const FormatException('Invalid collision reference manifest.');
    }
    final value = maps[map.name];
    if (value is! Map<String, dynamic>) {
      throw FormatException('Missing collision reference for ${map.name}.');
    }

    final sourceBounds = _rect(value['sourceBounds'], 'sourceBounds');
    if (sourceBounds.width <= 0 || sourceBounds.height <= 0) {
      throw FormatException('Invalid source bounds for ${map.name}.');
    }

    Offset project(Offset point) {
      final attackPoint = Offset(
        attackTargetBounds.left +
            (point.dx - sourceBounds.left) *
                attackTargetBounds.width /
                sourceBounds.width,
        attackTargetBounds.top +
            (point.dy - sourceBounds.top) *
                attackTargetBounds.height /
                sourceBounds.height,
      );
      if (!isDefense) return attackPoint;
      const worldWidth = 1000.0 * (16 / 9);
      return Offset(worldWidth - attackPoint.dx, 1000 - attackPoint.dy);
    }

    List<Offset> polygon(Object? encoded, String label) {
      if (encoded is! List || encoded.length < 2) {
        throw FormatException('Invalid $label polygon for ${map.name}.');
      }
      final points = <Offset>[
        for (final point in encoded) project(_point(point, label)),
      ];
      if ((points.first - points.last).distanceSquared > 1e-9) {
        points.add(points.first);
      }
      return List<Offset>.unmodifiable(points);
    }

    List<List<Offset>> polygons(Object? encoded, String label) {
      if (encoded is! List) {
        throw FormatException('Invalid $label list for ${map.name}.');
      }
      return List<List<Offset>>.unmodifiable([
        for (var index = 0; index < encoded.length; index += 1)
          polygon(encoded[index], '$label[$index]'),
      ]);
    }

    final outer = polygon(value['outer'], 'outer');
    final interiors = polygons(value['interiors'], 'interiors');
    final heightBoxes = polygons(value['heightBoxes'], 'heightBoxes');
    final maskContours = List<List<Offset>>.unmodifiable([
      outer,
      ...interiors,
    ]);

    final outerGroup = VisionCollisionGroup.geometry(
      points: outer,
      kind: VisionCollisionKind.maskBoundary,
      isClosed: true,
      isOuterBoundary: true,
    );
    final groups = <VisionCollisionGroup>[
      outerGroup,
      for (final interior in interiors)
        VisionCollisionGroup.geometry(
          points: interior,
          kind: VisionCollisionKind.maskBoundary,
          isClosed: true,
          nestingDepth: 1,
        ),
      for (final box in heightBoxes)
        VisionCollisionGroup.geometry(
          points: box,
          kind: VisionCollisionKind.structuralObstacle,
          isClosed: true,
          removesOwnEdgesWhenInside: true,
        ),
    ];

    final maskSegments = List<VisionSegment>.unmodifiable([
      for (final contour in maskContours) ..._segments(contour),
    ]);
    final collisionSegments = <VisionSegment>[];
    final collisionKeys = <String>{};
    for (final group in groups) {
      for (final segment in group.segments) {
        if (collisionKeys.add(visionSegmentKey(segment))) {
          collisionSegments.add(segment);
        }
      }
    }

    return VisionBoundary(
      segments: List<VisionSegment>.unmodifiable(collisionSegments),
      maskSegments: maskSegments,
      contours: maskContours,
      collisionGroups: List<VisionCollisionGroup>.unmodifiable(groups),
      outerGroupId: outerGroup.id,
      fillRule: VisionFillRule.evenOdd,
      alwaysOnSegments: outerGroup.segments,
    );
  }

  static Rect _rect(Object? value, String label) {
    if (value is! List || value.length != 4) {
      throw FormatException('Invalid $label.');
    }
    final numbers = value.map(_number).toList(growable: false);
    return Rect.fromLTRB(numbers[0], numbers[1], numbers[2], numbers[3]);
  }

  static Offset _point(Object? value, String label) {
    if (value is! List || value.length != 2) {
      throw FormatException('Invalid point in $label.');
    }
    return Offset(_number(value[0]), _number(value[1]));
  }

  static double _number(Object? value) {
    if (value is! num || !value.toDouble().isFinite) {
      throw const FormatException('Collision coordinates must be finite.');
    }
    return value.toDouble();
  }

  static List<VisionSegment> _segments(List<Offset> points) => [
        for (var index = 1; index < points.length; index += 1)
          if ((points[index] - points[index - 1]).distanceSquared > 1e-9)
            VisionSegment(points[index - 1], points[index]),
      ];
}
