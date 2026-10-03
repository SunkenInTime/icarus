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

/// One measured destination floor as a cone overlooks it. Built from plain
/// geometry, so a worker isolate can make one; paths are made when painted.
class SvgFloorLayer {
  SvgFloorLayer(this.rings, this.evenOdd, this.shadows);

  /// The floor's footprint, in source coordinates.
  final List<List<Offset>> rings;
  final bool evenOdd;
  final SvgFloorShadows shadows;

  late final Path floor = Path()
    ..fillType = evenOdd ? PathFillType.evenOdd : PathFillType.nonZero
    ..addPolygonRings(rings);
}

/// The shadows the SVG wall volumes cast onto one measured, horizontal floor,
/// for a target standing on it, whose eye can differ from the observer's.
///
/// They are kept as shapes rather than subtracted: a painter fills the floor
/// and erases them, so a cone costs no path operations however many walls
/// stand between it and the floor. Faces are wound one way, so their nonzero
/// union is their shadow; caps keep their footprint's fill rule and holes.
class SvgFloorShadows {
  SvgFloorShadows._(this.faces, this.caps);

  final List<List<Offset>> faces;
  final List<(List<List<Offset>>, bool)> caps;

  late final Path facesPath = () {
    final path = Path()..fillType = PathFillType.nonZero;
    for (final face in faces) {
      path.addPolygon(face, true);
    }
    return path;
  }();

  late final List<Path> capPaths = [
    for (final (rings, evenOdd) in caps)
      Path()
        ..fillType = evenOdd ? PathFillType.evenOdd : PathFillType.nonZero
        ..addPolygonRings(rings)
  ];

  /// Erases the shadows from what [canvas] has drawn so far in this layer.
  void erase(Canvas canvas) {
    final clear = Paint()..blendMode = BlendMode.clear;
    for (final cap in capPaths) {
      canvas.drawPath(cap, clear);
    }
    canvas.drawPath(facesPath, clear);
  }

  /// [area] less the shadows, as one path. Each shadow is subtracted on its
  /// own: near a wall endpoint, overlapping thin contours in one path can
  /// make Skia's path operation fail. Slow; for reports and tests.
  Path subtractFrom(Path area) {
    var visible = area;
    for (final cap in capPaths) {
      if (!cap.getBounds().isEmpty) {
        visible = Path.combine(PathOperation.difference, visible, cap);
      }
    }
    for (final face in faces) {
      final side = Path()..addPolygon(face, true);
      if (!side.getBounds().isEmpty) {
        visible = Path.combine(PathOperation.difference, visible, side);
      }
    }
    return visible;
  }
}

extension on Path {
  void addPolygonRings(List<List<Offset>> rings) {
    for (final ring in rings) {
      addPolygon(ring, true);
    }
  }
}

/// Projects the wall volumes onto a target standing anywhere in [bounds].
/// Clipping projected faces to [bounds] in double precision keeps distant
/// shadows out of Skia's float coordinates.
SvgFloorShadows svgFloorShadows({
  required Rect bounds,
  required Offset origin,
  required double observerEye,
  required double targetEye,
  required Iterable<SvgFloorOccluder> walls,
}) {
  final faces = <List<Offset>>[];
  final caps = <(List<List<Offset>>, bool)>[];
  if (bounds.isEmpty) return SvgFloorShadows._(faces, caps);
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
      for (final factor in [near, if (far != null && far != near) far]) {
        final rings = [
          for (final ring in wall.rings)
            _clipRect(
                [for (final p in ring) origin + (p - origin) * factor], bounds)
        ].where((ring) => ring.length >= 3).toList();
        if (rings.isNotEmpty) caps.add((rings, wall.evenOdd));
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
          if (face.length >= 3) faces.add(_counterClockwise(face));
        }
      }
    }
  }
  return SvgFloorShadows._(faces, caps);
}

/// [floor] inside [sector], less the shadows the walls cast on a target
/// standing on it. The boolean form of what [SvgFloorShadows] paints.
Path visibleSvgFloor({
  required Path floor,
  required Path sector,
  required Offset origin,
  required double observerEye,
  required double targetEye,
  required Iterable<SvgFloorOccluder> walls,
}) {
  final visible = Path.combine(PathOperation.intersect, floor, sector);
  final bounds = visible.getBounds();
  if (bounds.isEmpty) return visible;
  return svgFloorShadows(
          bounds: bounds,
          origin: origin,
          observerEye: observerEye,
          targetEye: targetEye,
          walls: walls)
      .subtractFrom(visible);
}

List<Offset> _counterClockwise(List<Offset> points) {
  var twiceArea = 0.0;
  for (var i = 0; i < points.length; i++) {
    twiceArea += _cross(points[i], points[(i + 1) % points.length]);
  }
  return twiceArea < 0 ? points.reversed.toList() : points;
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
