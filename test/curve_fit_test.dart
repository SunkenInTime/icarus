import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/curve_fit.dart';

/// A quarter circle of [radius], a point every half a unit along it, with
/// a shake [shake] high and 16 long, the way a hand shakes.
List<Offset> _arc(double radius, {double shake = 0}) {
  final length = radius * math.pi / 2;
  final count = (length / 0.5).round();
  return [
    for (var i = 0; i <= count; i++)
      Offset.fromDirection(
        i / count * math.pi / 2,
        radius + shake * math.sin(i / count * length / 16 * 2 * math.pi),
      ),
  ];
}

double _furthestFromCircle(List<CurvePiece> pieces, double radius) {
  var furthest = 0.0;
  for (final piece in pieces) {
    for (var step = 0; step <= 50; step++) {
      furthest = math.max(
        furthest,
        (piece.at(step / 50).distance - radius).abs(),
      );
    }
  }
  return furthest;
}

void main() {
  test('a straight run of points is one straight piece', () {
    final pieces = fitCurve(
      [for (var x = 0.0; x <= 200; x++) Offset(x, x / 2)],
      1,
      directionReach: 6,
    );
    expect(pieces, hasLength(1));
    for (var step = 0; step <= 10; step++) {
      final point = pieces.single.at(step / 10);
      expect(point.dy, closeTo(point.dx / 2, 1e-6));
    }
  });

  test('an arc is a few pieces that stay within the tolerance of it', () {
    final pieces = fitCurve(_arc(120), 1, directionReach: 6);
    expect(pieces.length, lessThanOrEqualTo(2));
    expect(_furthestFromCircle(pieces, 120), lessThan(1));
  });

  test('a shake smaller than the tolerance is left out', () {
    // The points wander 1.5 either side of the circle, a dozen times along
    // it, turning hundreds of degrees more than a quarter circle does. The
    // curve turns the quarter circle and little else.
    double turning(List<Offset> path) {
      var total = 0.0;
      for (var i = 2; i < path.length; i++) {
        var turn = ((path[i] - path[i - 1]).direction -
                (path[i - 1] - path[i - 2]).direction)
            .abs();
        if (turn > math.pi) turn = 2 * math.pi - turn;
        total += turn;
      }
      return total * 180 / math.pi;
    }

    final points = _arc(120, shake: 1.5);
    final pieces = fitCurve(points, 3, directionReach: 6);
    final curve = [
      for (final piece in pieces)
        for (var step = 0; step < 50; step++) piece.at(step / 50),
      pieces.last.end,
    ];
    expect(turning(points), greaterThan(700));
    expect(turning(curve), lessThan(150));
  });

  test('a turn larger than the tolerance is kept', () {
    // A bump 10 tall in a straight run: the curve goes over it.
    final points = [
      for (var x = 0.0; x <= 120; x++)
        Offset(
            x, x > 50 && x < 70 ? -10 * math.sin((x - 50) / 20 * math.pi) : 0),
    ];
    final pieces = fitCurve(points, 3, directionReach: 6);
    var highest = 0.0;
    for (final piece in pieces) {
      for (var step = 0; step <= 50; step++) {
        highest = math.min(highest, piece.at(step / 50).dy);
      }
    }
    expect(highest, lessThan(-7));
  });

  test('pieces join without a kink', () {
    final points = [
      for (var x = 0.0; x <= 300; x++) Offset(x, 40 * math.sin(x / 30)),
    ];
    final pieces = fitCurve(points, 1, directionReach: 6);
    expect(pieces.length, greaterThan(1));
    for (var i = 1; i < pieces.length; i++) {
      expect(pieces[i].start, pieces[i - 1].end);
      final turn = pieces[i].startDirection.direction -
          pieces[i - 1].endDirection.direction;
      expect(turn.abs(), lessThan(1e-6));
    }
  });

  test('the curve carries on in the direction it is given', () {
    final pieces = fitCurve(
      [for (var x = 0.0; x <= 60; x++) Offset(x, 0)],
      3,
      startDirection: Offset.fromDirection(0.3),
      directionReach: 6,
    );
    expect(pieces.first.startDirection.direction, closeTo(0.3, 1e-9));
  });

  test('a piece split in two is the same curve', () {
    const piece = CurvePiece(
        Offset(0, 0), Offset(30, 60), Offset(80, -20), Offset(100, 40));
    final (before, after) = piece.splitAt(0.3);
    expect(before.end, after.start);
    expect((before.at(0.5) - piece.at(0.15)).distance, lessThan(1e-9));
    expect((after.at(0.5) - piece.at(0.65)).distance, lessThan(1e-9));
    expect(
      before.endDirection.direction,
      closeTo(after.startDirection.direction, 1e-9),
    );
  });

  test('straight steps along a piece stay within the tolerance asked', () {
    const piece = CurvePiece(
        Offset(0, 0), Offset(30, 60), Offset(80, -20), Offset(100, 40));
    final steps = piece.stepsWithin(0.1);
    var furthest = 0.0;
    for (var i = 0; i < steps; i++) {
      final from = piece.at(i / steps), to = piece.at((i + 1) / steps);
      // The curve half way along the step, against the step's middle.
      furthest = math.max(
        furthest,
        (piece.at((i + 0.5) / steps) - (from + to) / 2).distance,
      );
    }
    expect(furthest, lessThan(0.1));
  });
}
