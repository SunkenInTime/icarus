import 'dart:math' as math;
import 'dart:ui';

/// A painted footprint extruded through absolute source-height intervals.
class SvgFloorOccluder {
  SvgFloorOccluder(this.rings, this.evenOdd, this.bands)
      : bounds = _bounds(rings.expand((ring) => ring));

  final List<List<Offset>> rings;
  final bool evenOdd;
  final List<(double, double)> bands;
  final Rect bounds;
}

/// Projects the same SVG wall volumes onto one measured, horizontal floor.
/// A target stands on that floor, so its eye can differ from the observer's.
/// Clipping projected faces in double precision keeps distant shadows out of
/// Skia's float coordinates and preserves holes in the painted footprints.
Path visibleSvgFloor({
  required Path floor,
  required Path sector,
  required Offset origin,
  required double observerEye,
  required double targetEye,
  required Iterable<SvgFloorOccluder> walls,
}) {
  var visible = Path.combine(PathOperation.intersect, floor, sector);
  final bounds = visible.getBounds();
  if (bounds.isEmpty) return visible;
  final influence = bounds.expandToInclude(Rect.fromPoints(origin, origin));
  final delta = targetEye - observerEye;
  for (final wall in walls) {
    if (!wall.bounds.overlaps(influence)) continue;
    for (final band in wall.bands) {
      double first, last;
      if (delta == 0) {
        if (observerEye < band.$1 || observerEye > band.$2) continue;
        first = 0;
        last = 1;
      } else {
        final a = (band.$1 - observerEye) / delta;
        final b = (band.$2 - observerEye) / delta;
        first = math.max(0, math.min(a, b));
        last = math.min(1, math.max(a, b));
        if (last <= 0 || first > last) continue;
      }
      final near = 1 / last;
      final far = first == 0 ? null : 1 / first;
      // Horizontal caps matter when an eye starts below an overhead footprint.
      // Subtraction distributes over their union; even-odd holes stay intact.
      for (final factor in [near, if (far != null && far != near) far]) {
        final cap = Path()
          ..fillType =
              wall.evenOdd ? PathFillType.evenOdd : PathFillType.nonZero;
        for (final ring in wall.rings) {
          final clipped = _clipRect(
              [for (final p in ring) origin + (p - origin) * factor], bounds);
          if (clipped.length >= 3) cap.addPolygon(clipped, true);
        }
        if (!cap.getBounds().isEmpty) {
          visible = Path.combine(PathOperation.difference, visible, cap);
        }
      }
      for (final ring in wall.rings) {
        for (var i = 0; i < ring.length; i++) {
          final a = ring[i], b = ring[(i + 1) % ring.length];
          final av = a - origin, bv = b - origin;
          final cross = _cross(av, bv);
          if (cross == 0) continue;
          final sign = cross.sign;
          final edge = b - a;
          var face = _rectangle(bounds);
          face = _clip(face, (p) => sign * _cross(av, p - origin));
          face = _clip(face, (p) => -sign * _cross(bv, p - origin));
          face = _clip(
              face, (p) => -sign * _cross(edge, p - (origin + av * near)));
          if (far != null) {
            face = _clip(
                face, (p) => sign * _cross(edge, p - (origin + av * far)));
          }
          if (face.length >= 3) {
            // Subtraction distributes over the union of projected faces.
            // Keep each face simple: near a wall endpoint, overlapping thin
            // contours in one path can make Skia's path operation fail.
            final side = Path()..addPolygon(face, true);
            if (!side.getBounds().isEmpty) {
              visible = Path.combine(PathOperation.difference, visible, side);
            }
          }
        }
      }
    }
  }
  return visible;
}

List<Offset> _rectangle(Rect r) =>
    [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];

List<Offset> _clipRect(List<Offset> points, Rect r) {
  var result = _clip(points, (p) => p.dx - r.left);
  result = _clip(result, (p) => r.right - p.dx);
  result = _clip(result, (p) => p.dy - r.top);
  return _clip(result, (p) => r.bottom - p.dy);
}

List<Offset> _clip(List<Offset> points, double Function(Offset) distance) {
  if (points.isEmpty) return points;
  final result = <Offset>[];
  for (var i = 0; i < points.length; i++) {
    final a = points[i], b = points[(i + 1) % points.length];
    final da = distance(a), db = distance(b);
    if (da >= 0) result.add(a);
    if ((da >= 0) != (db >= 0)) result.add(a + (b - a) * (da / (da - db)));
  }
  return result;
}

double _cross(Offset a, Offset b) => a.dx * b.dy - a.dy * b.dx;

Rect _bounds(Iterable<Offset> points) {
  var left = double.infinity, top = double.infinity;
  var right = double.negativeInfinity, bottom = double.negativeInfinity;
  for (final point in points) {
    left = math.min(left, point.dx);
    top = math.min(top, point.dy);
    right = math.max(right, point.dx);
    bottom = math.max(bottom, point.dy);
  }
  return Rect.fromLTRB(left, top, right, bottom);
}
