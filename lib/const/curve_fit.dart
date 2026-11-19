import 'dart:math' as math;
import 'dart:ui';

/// One piece of a fitted curve: a cubic Bézier from [start] to [end].
class CurvePiece {
  const CurvePiece(this.start, this.control1, this.control2, this.end);

  final Offset start;
  final Offset control1;
  final Offset control2;
  final Offset end;

  Offset at(double t) {
    final m = 1 - t;
    return start * (m * m * m) +
        control1 * (3 * m * m * t) +
        control2 * (3 * m * t * t) +
        end * (t * t * t);
  }

  /// The direction the piece leaves [start] in, a unit long.
  Offset get startDirection => _unit(
        control1 != start
            ? control1 - start
            : control2 != start
                ? control2 - start
                : end - start,
      );

  /// The direction the piece arrives at [end] in, a unit long.
  Offset get endDirection => _unit(
        control2 != end
            ? end - control2
            : control1 != end
                ? end - control1
                : end - start,
      );

  /// The piece up to [t], and the rest of it.
  (CurvePiece, CurvePiece) splitAt(double t) {
    final a = Offset.lerp(start, control1, t)!;
    final b = Offset.lerp(control1, control2, t)!;
    final c = Offset.lerp(control2, end, t)!;
    final ab = Offset.lerp(a, b, t)!;
    final bc = Offset.lerp(b, c, t)!;
    final middle = Offset.lerp(ab, bc, t)!;
    return (
      CurvePiece(start, a, ab, middle),
      CurvePiece(middle, bc, c, end),
    );
  }

  /// How many straight steps follow the piece to within [tolerance].
  int stepsWithin(double tolerance) {
    final bend = math.max(
      (start - control1 * 2 + control2).distance,
      (control1 - control2 * 2 + end).distance,
    );
    return math.max(1, math.sqrt(3 * bend / (4 * tolerance)).ceil());
  }
}

/// A few smooth pieces that pass within [tolerance] of every one of
/// [points], which are a path's points in order, close together.
///
/// A wobble smaller than [tolerance] is left out, and anything larger is
/// kept, so the curve is smooth where the path meant to be and still turns
/// where the path turned. The pieces join without a kink. The curve leaves
/// the first point along [startDirection] when given, so that it can carry
/// on from a curve that ended there.
///
/// Schneider's algorithm, from Graphics Gems (1990).
List<CurvePiece> fitCurve(
  List<Offset> points,
  double tolerance, {
  Offset? startDirection,
  required double directionReach,
}) {
  if (points.length < 2) return const [];
  final pieces = <CurvePiece>[];
  _fit(
    points,
    0,
    points.length - 1,
    startDirection ?? _directionFrom(points, 0, 1, directionReach),
    _directionFrom(points, points.length - 1, -1, directionReach),
    tolerance * tolerance,
    directionReach,
    pieces,
  );
  return pieces;
}

Offset _unit(Offset v) => v.distance == 0 ? v : v / v.distance;

double _dot(Offset a, Offset b) => a.dx * b.dx + a.dy * b.dy;

/// The direction of the path from [points] at [from], looking [step] way
/// along it: towards the points within [reach], all of them, so that one
/// uneven point does not set it.
Offset _directionFrom(List<Offset> points, int from, int step, double reach) {
  var towards = Offset.zero;
  for (var to = from + step; to >= 0 && to < points.length; to += step) {
    final offset = points[to] - points[from];
    towards += offset;
    if (offset.distance >= reach) break;
  }
  return _unit(towards);
}

void _fit(
  List<Offset> points,
  int first,
  int last,
  Offset startDirection,
  Offset backDirection,
  double toleranceSquared,
  double directionReach,
  List<CurvePiece> pieces,
) {
  // Where along the piece each point falls, first by distance along the
  // path, then moved towards the nearest place on each attempt.
  var along = <double>[0];
  for (var i = first + 1; i <= last; i++) {
    along.add(along.last + (points[i] - points[i - 1]).distance);
  }
  final length = along.last;

  // Two points, or points all in one place (a pointer shaking where it
  // stands), have no shape to fit: a straight piece between them.
  if (last - first == 1 || length == 0) {
    final third = (points[last] - points[first]).distance / 3;
    pieces.add(CurvePiece(
      points[first],
      points[first] + startDirection * third,
      points[last] + backDirection * third,
      points[last],
    ));
    return;
  }
  along = [for (final distance in along) distance / length];

  var piece =
      _bestPiece(points, first, last, along, startDirection, backDirection);
  var (error, worst) = _worstMiss(points, first, last, piece, along);
  if (error < toleranceSquared) {
    pieces.add(piece);
    return;
  }
  if (error < toleranceSquared * 16) {
    for (var attempt = 0; attempt < 4; attempt++) {
      along = [
        for (var i = first; i <= last; i++)
          _nearer(piece, points[i], along[i - first]),
      ];
      piece =
          _bestPiece(points, first, last, along, startDirection, backDirection);
      (error, worst) = _worstMiss(points, first, last, piece, along);
      if (error < toleranceSquared) {
        pieces.add(piece);
        return;
      }
    }
  }

  // One piece cannot do it: two, meeting where it missed by most, running
  // through that point in the direction the path has there.
  var through = Offset.zero;
  for (var away = 1; worst - away >= first && worst + away <= last; away++) {
    final across = points[worst + away] - points[worst - away];
    through += across;
    if (across.distance >= 2 * directionReach) break;
  }
  through = _unit(through);
  if (through == Offset.zero) {
    through = _unit(points[worst] - points[worst - 1]);
  }
  _fit(points, first, worst, startDirection, -through, toleranceSquared,
      directionReach, pieces);
  _fit(points, worst, last, through, backDirection, toleranceSquared,
      directionReach, pieces);
}

/// The piece from the first point to the last that comes closest to the
/// points between, by least squares. It leaves the first point along
/// [startDirection]; [backDirection] is the way back along the path from
/// the last.
CurvePiece _bestPiece(
  List<Offset> points,
  int first,
  int last,
  List<double> along,
  Offset startDirection,
  Offset backDirection,
) {
  final start = points[first], end = points[last];
  var c00 = 0.0, c01 = 0.0, c11 = 0.0, x0 = 0.0, x1 = 0.0;
  for (var i = 0; i <= last - first; i++) {
    final t = along[i], m = 1 - t;
    final b0 = m * m * m,
        b1 = 3 * m * m * t,
        b2 = 3 * m * t * t,
        b3 = t * t * t;
    final a0 = startDirection * b1, a1 = backDirection * b2;
    c00 += _dot(a0, a0);
    c01 += _dot(a0, a1);
    c11 += _dot(a1, a1);
    final rest = points[first + i] - (start * (b0 + b1) + end * (b2 + b3));
    x0 += _dot(a0, rest);
    x1 += _dot(a1, rest);
  }
  final determinant = c00 * c11 - c01 * c01;
  final span = (end - start).distance;
  var out =
      determinant.abs() < 1e-12 ? 0.0 : (x0 * c11 - x1 * c01) / determinant;
  var back =
      determinant.abs() < 1e-12 ? 0.0 : (c00 * x1 - c01 * x0) / determinant;
  // A control point behind its end would loop the piece: fall back to a
  // third of the way, as for two points.
  if (out < 1e-6 * span || back < 1e-6 * span) out = back = span / 3;
  return CurvePiece(
      start, start + startDirection * out, end + backDirection * back, end);
}

/// The square of the furthest any point is from where it falls on [piece],
/// and which point that is.
(double, int) _worstMiss(
  List<Offset> points,
  int first,
  int last,
  CurvePiece piece,
  List<double> along,
) {
  var worst = 0.0, at = (first + last) ~/ 2;
  for (var i = first + 1; i < last; i++) {
    final miss = (piece.at(along[i - first]) - points[i]).distanceSquared;
    if (miss >= worst) {
      worst = miss;
      at = i;
    }
  }
  return (worst, at);
}

/// A place on [piece] nearer [point] than [t] is: one step of Newton's
/// method.
double _nearer(CurvePiece piece, Offset point, double t) {
  final m = 1 - t;
  final position = piece.at(t);
  final velocity = (piece.control1 - piece.start) * (3 * m * m) +
      (piece.control2 - piece.control1) * (6 * m * t) +
      (piece.end - piece.control2) * (3 * t * t);
  final acceleration =
      (piece.control2 - piece.control1 * 2 + piece.start) * (6 * m) +
          (piece.end - piece.control2 * 2 + piece.control1) * (6 * t);
  final slope = _dot(velocity, velocity) + _dot(position - point, acceleration);
  if (slope == 0) return t;
  return (t - _dot(position - point, velocity) / slope).clamp(0.0, 1.0);
}
