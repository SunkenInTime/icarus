import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Something that blocks sight for a moment, on top of the map's walls: a
/// smoke, or a wall of smoke or fire. Positions are canonical world units,
/// as placed widgets store them. It blocks at every eye height.
sealed class VisionOccluder {
  const VisionOccluder();

  /// Whether any of it lies within [reach] of [origin].
  bool reaches(Offset origin, double reach);
}

/// A smoke: a sphere seen from above.
@immutable
class CircleOccluder extends VisionOccluder {
  const CircleOccluder(this.centre, this.radius);

  final Offset centre;
  final double radius;

  CircleOccluder map(Offset Function(Offset) point, double scale) =>
      CircleOccluder(point(centre), radius * scale);

  @override
  bool reaches(Offset origin, double reach) =>
      (centre - origin).distance < reach + radius;

  /// What this smoke hides from [origin], within [reach] of it: the smoke
  /// and the shadow behind it, in the space [origin] is in. Null when
  /// [origin] is inside it, which hides everything.
  List<Offset>? shadow(Offset origin, double reach) {
    final toCentre = centre - origin;
    final distance = toCentre.distance;
    // On its rim counts as inside: the shadow would be a half-plane.
    if (distance <= radius * 1.001) return null;
    final heading = math.atan2(toCentre.dy, toCentre.dx);
    final spread = math.asin(radius / distance);
    final tangent = math.sqrt(distance * distance - radius * radius);
    // Far enough that the shadow's far edge lies beyond the cone's reach,
    // and no farther: path operations fail on runaway coordinates.
    final far = math.min(
        (reach + distance) * distance / tangent * 1.5, (reach + distance) * 50);
    Offset along(double angle, double length) =>
        origin + Offset(math.cos(angle), math.sin(angle)) * length;
    // The near side of the circle, tangent to tangent, then out along the
    // tangents. The far side of the circle lies inside the shadow.
    final points = <Offset>[];
    const steps = 16;
    final start = heading + spread + math.pi / 2;
    final sweep = math.pi - 2 * spread;
    for (var i = 0; i <= steps; i++) {
      final angle = start + sweep * i / steps;
      points.add(centre + Offset(math.cos(angle), math.sin(angle)) * radius);
    }
    points
      ..add(along(heading - spread, far))
      ..add(along(heading + spread, far));
    return points;
  }

  @override
  bool operator ==(Object other) =>
      other is CircleOccluder &&
      other.centre == centre &&
      other.radius == radius;

  @override
  int get hashCode => Object.hash(centre, radius);
}

/// A wall of smoke or fire, as a line through [points].
@immutable
class LineOccluder extends VisionOccluder {
  const LineOccluder(this.points);

  final List<Offset> points;

  LineOccluder map(Offset Function(Offset) point) =>
      LineOccluder([for (final p in points) point(p)]);

  @override
  bool reaches(Offset origin, double reach) {
    for (var i = 0; i + 1 < points.length; i++) {
      final a = points[i], b = points[i + 1];
      final edge = b - a;
      final length = edge.distanceSquared;
      final t = length == 0
          ? 0.0
          : (((origin - a).dx * edge.dx + (origin - a).dy * edge.dy) / length)
              .clamp(0.0, 1.0);
      if ((a + edge * t - origin).distance < reach) return true;
    }
    return false;
  }

  /// What each segment hides from [origin], within [reach] of it.
  List<List<Offset>> shadows(Offset origin, double reach) {
    final out = <List<Offset>>[];
    for (var i = 0; i + 1 < points.length; i++) {
      final a = points[i], b = points[i + 1];
      final toA = a - origin, toB = b - origin;
      // Seen edge on, a segment hides nothing.
      if ((toA.dx * toB.dy - toA.dy * toB.dx).abs() < 1e-9) continue;
      // Out along both ends, then round between them at a radius past
      // the cone's reach: a straight far edge between the two ends cuts
      // back inside the reach when the wall is close.
      final far = (reach + math.max(toA.distance, toB.distance)) * 2;
      final fromAngle = math.atan2(toA.dy, toA.dx);
      var sweep = math.atan2(toB.dy, toB.dx) - fromAngle;
      if (sweep > math.pi) sweep -= 2 * math.pi;
      if (sweep < -math.pi) sweep += 2 * math.pi;
      final steps = math.max(1, (sweep.abs() / (math.pi / 36)).ceil());
      out.add([
        a,
        b,
        for (var step = steps; step >= 0; step--)
          origin +
              Offset(math.cos(fromAngle + sweep * step / steps),
                      math.sin(fromAngle + sweep * step / steps)) *
                  far,
      ]);
    }
    return out;
  }

  @override
  bool operator ==(Object other) =>
      other is LineOccluder && listEquals(other.points, points);

  @override
  int get hashCode => Object.hashAll(points);
}

/// Whether [origin] stands inside a smoke, where nothing beyond it shows.
bool standsInsideSmoke(Offset origin, List<VisionOccluder> occluders) =>
    occluders.any((occluder) =>
        occluder is CircleOccluder && occluder.shadow(origin, 0) == null);

/// What [occluders] hide from [origin], within [reach] of it: one path, in
/// the space [origin] is in, for the cone painter to erase. Null when they
/// hide nothing. Erasing at paint time keeps path operations, which cost a
/// millisecond or more against a cone's wall cut, off the UI thread.
Path? occluderShadows(
  Offset origin,
  double reach,
  List<VisionOccluder> occluders,
) {
  final shadows = Path()..fillType = PathFillType.nonZero;
  var any = false;
  for (final occluder in occluders) {
    final polygons = switch (occluder) {
      CircleOccluder() => [occluder.shadow(origin, reach)],
      LineOccluder() => occluder.shadows(origin, reach),
    };
    for (final polygon in polygons) {
      if (polygon == null) continue;
      // One winding for all, so overlapping shadows add up rather than
      // cancel under the non-zero rule.
      shadows.addPolygon(
          _signedArea(polygon) < 0 ? polygon.reversed.toList() : polygon, true);
      any = true;
    }
  }
  return any ? shadows : null;
}

double _signedArea(List<Offset> polygon) {
  var area = 0.0;
  for (var i = 0; i < polygon.length; i++) {
    final a = polygon[i], b = polygon[(i + 1) % polygon.length];
    area += a.dx * b.dy - b.dx * a.dy;
  }
  return area / 2;
}
