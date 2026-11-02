import 'dart:math' as math;
import 'dart:ui' show Offset;

/// The most points a wall path holds: its end and six bends. The icon is the
/// wall's first point and isn't saved.
const maxWallPathPoints = 7;

/// How finely each stretch of a wall is drawn.
const _samplesPerStretch = 16;

/// The smooth line through [points], in the same space. It passes through
/// every point, so a handle always sits on the wall, and a centripetal curve
/// can't loop or overshoot where the points are unevenly spaced.
List<Offset> smoothWallLine(List<Offset> points) {
  if (points.length < 3) return List<Offset>.of(points);
  final line = <Offset>[points.first];
  for (var i = 0; i + 1 < points.length; i++) {
    final p1 = points[i];
    final p2 = points[i + 1];
    // Past the ends the line carries straight on.
    final p0 = i == 0 ? p1 * 2 - p2 : points[i - 1];
    final p3 = i + 2 == points.length ? p2 * 2 - p1 : points[i + 2];
    double step(Offset a, Offset b) =>
        math.max(math.sqrt((b - a).distance), 1e-6);
    final t1 = step(p0, p1);
    final t2 = t1 + step(p1, p2);
    final t3 = t2 + step(p2, p3);
    Offset lerp(Offset a, double ta, Offset b, double tb, double t) =>
        a * ((tb - t) / (tb - ta)) + b * ((t - ta) / (tb - ta));
    for (var sample = 1; sample <= _samplesPerStretch; sample++) {
      final t = t1 + (t2 - t1) * sample / _samplesPerStretch;
      final a1 = lerp(p0, 0, p1, t1, t);
      final a2 = lerp(p1, t1, p2, t2, t);
      final a3 = lerp(p2, t2, p3, t3, t);
      final b1 = lerp(a1, 0, a2, t2, t);
      final b2 = lerp(a2, t1, a3, t3, t);
      line.add(lerp(b1, t1, b2, t2, t));
    }
  }
  return line;
}

/// How long [line] is, in its own units.
double wallLineLength(List<Offset> line) {
  var length = 0.0;
  for (var i = 0; i + 1 < line.length; i++) {
    length += (line[i + 1] - line[i]).distance;
  }
  return length;
}

/// How long the wall of [path] is drawn, in the path's units.
double wallPathLength(List<Offset> path) =>
    wallLineLength(smoothWallLine([Offset.zero, ...path]));

/// [path] with [point] added at [index], no longer than [limit]. A new point
/// on a curved wall bends what's beside it a little, which can lengthen it,
/// so the whole wall shrinks by that much.
List<Offset> wallPathWithPoint(
  List<Offset> path,
  int index,
  Offset point, {
  required double limit,
}) {
  final added = [...path]..insert(index, point);
  final length = wallPathLength(added);
  if (length <= limit) return added;
  return [for (final offset in added) offset * (limit / length)];
}

/// The point [fraction] of the way along [line].
Offset pointAlongWall(List<Offset> line, double fraction) {
  final total = wallLineLength(line);
  var remaining = total * fraction;
  for (var i = 0; i + 1 < line.length; i++) {
    final span = (line[i + 1] - line[i]).distance;
    if (span > 0 && remaining <= span) {
      return Offset.lerp(line[i], line[i + 1], remaining / span)!;
    }
    remaining -= span;
  }
  return line.last;
}

/// [line] as [count] evenly spaced points, so two walls with different
/// numbers of points can be blended.
List<Offset> resampleWallLine(List<Offset> line, int count) => [
      for (var i = 0; i < count; i++) pointAlongWall(line, i / (count - 1)),
    ];

/// The middle of each stretch of the wall through [points], as drawn: where
/// a new bend can be pulled out of it.
List<Offset> wallStretchMiddles(List<Offset> points) {
  if (points.length < 3) {
    return [Offset.lerp(points.first, points.last, 0.5)!];
  }
  final line = smoothWallLine(points);
  return [
    for (var i = 0; i + 1 < points.length; i++)
      line[i * _samplesPerStretch + _samplesPerStretch ~/ 2],
  ];
}
