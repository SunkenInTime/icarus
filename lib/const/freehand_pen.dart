import 'dart:math' as math;
import 'dart:ui';

import 'package:icarus/const/curve_fit.dart';

/// Turns the pointer's positions during one freehand stroke into the
/// stroke's points.
///
/// A hand does not draw the line it means: it shakes, and a mouse reports it
/// in whole pixels, so a stroke drawn through the reports is lumpy. The pen
/// draws the smooth curve that stays within [tolerance] of where the pointer
/// went instead. A wobble smaller than that is left out; a turn larger than
/// that is kept, and a corner stays a corner, so small writing survives and
/// a long sweep comes out clean.
///
/// It does this while the stroke is drawn. The curve always reaches the
/// pointer, and the stretch just behind the pointer is still being shaped.
/// Further back than twice [settleBehind] the ink has settled and never
/// moves again, so lifting the pointer changes nothing on screen.
class FreehandPen {
  /// A pen put down at [start]. [unit] is the length of one screen pixel in
  /// the coordinates of the points, at the zoom the stroke is drawn at:
  /// every length below is that many screen pixels.
  FreehandPen(Offset start, {required this.unit})
      : _unsettled = [start],
        _pointer = start;

  final double unit;

  /// How far the curve may stray from the pointer's path.
  static const double tolerance = 3;

  /// How far behind the pointer the curve is settled, each time there is
  /// as much again of it unsettled.
  static const double settleBehind = 24;

  /// A turn of more than [cornerTurn] degrees, between the [cornerReach]
  /// before a place and the [cornerReach] after it, is a corner.
  static const double cornerReach = 9;
  static const double cornerTurn = 70;

  /// The length a direction along the path is measured over.
  static const double _directionReach = 6;

  /// How closely the points follow the curve: the editor's painter draws a
  /// curve through its points that stays this near the fitted one.
  static const double _pointTolerance = 0.25;

  /// A pointer that has travelled less than this is still a click.
  static const double _clickTravel = 2.5;

  /// The points of the curve that has settled, up to but not including
  /// where the unsettled path starts.
  final List<Offset> _settled = [];

  /// The pointer's path not yet settled, a pixel between points, starting
  /// where the settled curve ends.
  List<Offset> _unsettled;

  /// The direction the settled curve ends in, which the curve carries on
  /// in: null where the stroke starts and after a corner.
  Offset? _direction;

  Offset _pointer;
  double _travelled = 0;

  /// How far the pointer is past the last point of [_unsettled].
  double _pastLastPoint = 0;

  /// Moves the pointer to [pointer] and gives the stroke's points now.
  List<Offset> moveTo(Offset pointer) {
    final step = pointer - _pointer;
    final length = step.distance;
    if (length == 0) return points;

    // The pointer went straight from the last report to this one, as far
    // as anyone knows. Walking it a pixel at a time, settling as it goes,
    // makes a stroke the same however often the mouse reports.
    var next = unit - _pastLastPoint;
    while (next <= length) {
      _unsettled.add(_pointer + step * (next / length));
      _settleCorners();
      _settleBehindPointer();
      next += unit;
    }
    _pastLastPoint = (_pastLastPoint + length) % unit;
    _pointer = pointer;
    _travelled += length;
    return points;
  }

  /// The stroke's points: the settled curve, then the curve from there to
  /// the pointer.
  List<Offset> get points {
    if (_travelled < _clickTravel * unit) return [_unsettled.first];
    final toPointer = fitCurve(
      [..._unsettled, if (_unsettled.last != _pointer) _pointer],
      tolerance * unit,
      startDirection: _direction,
      directionReach: _directionReach * unit,
    );
    return [
      ..._settled,
      for (final piece in toPointer) ..._pointsAlong(piece),
      _pointer,
    ];
  }

  /// Settles the curve up to each corner the path has turned, once the path
  /// has run on far enough past it to tell it is one.
  void _settleCorners() {
    final reach = cornerReach.round();
    while (true) {
      final corner = _firstCorner(reach);
      if (corner == null) return;
      final pieces = fitCurve(
        _unsettled.sublist(0, corner + 1),
        tolerance * unit,
        startDirection: _direction,
        directionReach: _directionReach * unit,
      );
      for (final piece in pieces) {
        _settled.addAll(_pointsAlong(piece));
      }
      // The corner is given twice: the painter rounds a turn between the
      // midpoints either side of a point, and two points in one place
      // leave it nothing to round.
      _settled.add(_unsettled[corner]);
      _unsettled = _unsettled.sublist(corner);
      _direction = null;
    }
  }

  /// The first point of the unsettled path, after its start, that is a
  /// corner: where the path turns most sharply within [reach] points either
  /// way, by more than [cornerTurn].
  int? _firstCorner(int reach) {
    // The turn at a point needs the path [reach] past it, and whether it is
    // the sharpest nearby needs the turns [reach] past that.
    final known = _unsettled.length - 1 - reach;
    double turnAt(int i) {
      final before = _unsettled[i] - _unsettled[i - reach];
      final after = _unsettled[i + reach] - _unsettled[i];
      var turn = (after.direction - before.direction).abs();
      if (turn > math.pi) turn = 2 * math.pi - turn;
      return turn * 180 / math.pi;
    }

    for (var i = reach; i <= known - reach; i++) {
      final turn = turnAt(i);
      if (turn < cornerTurn) continue;
      var sharpest = true;
      for (var j = i - reach; j <= i + reach && sharpest; j++) {
        if (j < reach || j == i) continue;
        final other = turnAt(j);
        if (other > turn || (other == turn && j < i)) sharpest = false;
      }
      if (sharpest) return i;
    }
    return null;
  }

  /// Settles the curve up to [settleBehind] behind the pointer, once there
  /// is as much again of it unsettled.
  void _settleBehindPointer() {
    final behind = settleBehind.round();
    if (_unsettled.length - 1 < 2 * behind) return;
    final pieces = fitCurve(
      _unsettled,
      tolerance * unit,
      startDirection: _direction,
      directionReach: _directionReach * unit,
    );

    // Cut the curve at its nearest place to the path [settleBehind] back.
    final cut = _unsettled.length - 1 - behind;
    var cutPiece = 0, cutAt = 0.0, nearest = double.infinity;
    for (var i = 0; i < pieces.length; i++) {
      for (var step = 0; step <= 32; step++) {
        final distance =
            (pieces[i].at(step / 32) - _unsettled[cut]).distanceSquared;
        if (distance < nearest) {
          nearest = distance;
          cutPiece = i;
          cutAt = step / 32;
        }
      }
    }
    if (cutPiece == 0 && cutAt == 0) return;

    for (final piece in pieces.take(cutPiece)) {
      _settled.addAll(_pointsAlong(piece));
    }
    var end = pieces[cutPiece].start;
    var direction = pieces[cutPiece].startDirection;
    if (cutAt > 0) {
      final (settled, _) = pieces[cutPiece].splitAt(cutAt);
      _settled.addAll(_pointsAlong(settled));
      end = settled.end;
      direction = settled.endDirection;
    }
    _direction = direction == Offset.zero ? null : direction;
    _unsettled = [end, ..._unsettled.sublist(cut + 1)];
  }

  /// Points along [piece] from its start, without its end: closer together
  /// the more it bends.
  Iterable<Offset> _pointsAlong(CurvePiece piece) sync* {
    final steps = piece.stepsWithin(_pointTolerance * unit);
    for (var i = 0; i < steps; i++) {
      yield piece.at(i / steps);
    }
  }
}
