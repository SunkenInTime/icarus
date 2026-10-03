import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

/// A painted footprint extruded through absolute source-height intervals.
class SvgFloorOccluder {
  SvgFloorOccluder(this.rings, this.evenOdd, this.bands)
      : bounds = _bounds(rings.expand((ring) => ring));

  final List<List<Offset>> rings;
  final bool evenOdd;
  final List<(double, double)> bands;
  final Rect bounds;

  /// Every edge as ax, ay, bx, by, inside: which side of a to b the
  /// footprint lies on, 1 left, -1 right, 0 where a step either way cannot
  /// tell (a sliver thinner than the step).
  late final Float64List edges = () {
    final out = <double>[];
    for (final ring in rings) {
      for (var i = 0; i < ring.length; i++) {
        final a = ring[i], b = ring[(i + 1) % ring.length];
        if (a == b) continue;
        final mid = (a + b) / 2, along = (b - a) / (b - a).distance;
        final left = Offset(along.dy, -along.dx) * 1e-6;
        final inLeft = _inside(mid + left), inRight = _inside(mid - left);
        out.addAll([
          a.dx,
          a.dy,
          b.dx,
          b.dy,
          inLeft == inRight
              ? 0
              : inLeft
                  ? 1
                  : -1
        ]);
      }
    }
    return Float64List.fromList(out);
  }();

  bool _inside(Offset point) {
    var winding = 0;
    for (final ring in rings) {
      for (var i = 0; i < ring.length; i++) {
        final a = ring[i], b = ring[(i + 1) % ring.length];
        final side = _cross(b - a, point - a);
        if (a.dy <= point.dy && b.dy > point.dy && side > 0) winding++;
        if (a.dy > point.dy && b.dy <= point.dy && side < 0) winding--;
      }
    }
    return evenOdd ? winding.isOdd : winding != 0;
  }
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
  final ox = origin.dx, oy = origin.dy;
  final clip = _Clipper(bounds);
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
      final e = wall.edges;
      for (var k = 0; k < e.length; k += 5) {
        final avx = e[k] - ox, avy = e[k + 1] - oy;
        final bvx = e[k + 2] - ox, bvy = e[k + 3] - oy;
        final cross = avx * bvy - avy * bvx;
        if (cross == 0) continue;
        final ex = bvx - avx, ey = bvy - avy;
        // A shadow that runs on for ever is cast whole by the edges facing
        // the eye; an edge facing away only shades what they already shade.
        if (far == null && e[k + 4] != 0) {
          final eyeSide = ex * -avy - ey * -avx;
          if (eyeSide * e[k + 4] < 0) continue;
        }
        final sign = cross.sign;
        clip.reset();
        // Between the rays through the edge's ends, past its near copy.
        if (!clip.cut(sign * -avy, sign * avx, 0, ox, oy) ||
            !clip.cut(-sign * -bvy, -sign * bvx, 0, ox, oy) ||
            !clip.cut(
                -sign * -ey, -sign * ex, 0, ox + avx * near, oy + avy * near)) {
          continue;
        }
        if (far != null &&
            !clip.cut(
                sign * -ey, sign * ex, 0, ox + avx * far, oy + avy * far)) {
          continue;
        }
        final face = clip.polygon();
        if (face.length >= 3) faces.add(face);
      }
    }
  }
  return SvgFloorShadows._(faces, caps);
}

/// Sutherland-Hodgman clipping of a rectangle by half-planes, in flat
/// buffers: a face is clipped by three or four lines per edge, thousands of
/// times per cone, so no lists or closures per step.
class _Clipper {
  _Clipper(this.rect);

  final Rect rect;
  var _a = Float64List(32), _b = Float64List(32);
  var _n = 0;

  void reset() {
    _a[0] = rect.left;
    _a[1] = rect.top;
    _a[2] = rect.right;
    _a[3] = rect.top;
    _a[4] = rect.right;
    _a[5] = rect.bottom;
    _a[6] = rect.left;
    _a[7] = rect.bottom;
    _n = 4;
  }

  /// Keeps the side where nx * (x - px) + ny * (y - py) >= c. False when
  /// nothing is left.
  bool cut(double nx, double ny, double c, double px, double py) {
    if (_n == 0) return false;
    var allIn = true, anyIn = false;
    for (var i = 0; i < _n; i++) {
      final d = nx * (_a[i * 2] - px) + ny * (_a[i * 2 + 1] - py) - c;
      if (d >= 0) {
        anyIn = true;
      } else {
        allIn = false;
      }
    }
    if (allIn) return true;
    if (!anyIn) {
      _n = 0;
      return false;
    }
    if (_b.length < (_n + 1) * 2) _b = Float64List((_n + 1) * 4);
    var m = 0;
    for (var i = 0; i < _n; i++) {
      final j = (i + 1) % _n;
      final ax = _a[i * 2], ay = _a[i * 2 + 1];
      final bx = _a[j * 2], by = _a[j * 2 + 1];
      final da = nx * (ax - px) + ny * (ay - py) - c;
      final db = nx * (bx - px) + ny * (by - py) - c;
      if (da >= 0) {
        _b[m * 2] = ax;
        _b[m * 2 + 1] = ay;
        m++;
      }
      if ((da >= 0) != (db >= 0)) {
        final t = da / (da - db);
        _b[m * 2] = ax + (bx - ax) * t;
        _b[m * 2 + 1] = ay + (by - ay) * t;
        m++;
      }
    }
    final swap = _a;
    _a = _b;
    _b = swap;
    if (_a.length < _b.length) _a = Float64List(_b.length)..setAll(0, _a);
    _n = m;
    return _n >= 3;
  }

  /// The clipped face, wound one way so faces unite under nonzero fill.
  List<Offset> polygon() {
    var twiceArea = 0.0;
    for (var i = 0; i < _n; i++) {
      final j = (i + 1) % _n;
      twiceArea += _a[i * 2] * _a[j * 2 + 1] - _a[j * 2] * _a[i * 2 + 1];
    }
    final points = [
      for (var i = 0; i < _n; i++) Offset(_a[i * 2], _a[i * 2 + 1])
    ];
    return twiceArea < 0 ? points.reversed.toList() : points;
  }
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
