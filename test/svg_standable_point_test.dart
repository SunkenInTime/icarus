import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

import 'svg_height_visibility_test.dart' show data, rectangle, wall;

Map<String, dynamic> _floor(List<double> ring) => {
      'id': 'floor',
      'rings': [ring],
      'fillRule': 'nonzero'
    };

void main() {
  // A 100 x 100 floor with a 10 x 10 wall in its middle.
  final model = SvgHeightVisibility.fromJson(data(
    [
      wall('pillar', [rectangle(45, 45, 55, 55)])
    ],
    receiver: [_floor(rectangle(0, 0, 100, 100))],
  ));

  test('a point already on the floor is returned as it is', () {
    expect(
        model.standablePointNear(const Offset(20, 20)), const Offset(20, 20));
  });

  test('a point inside wall ink is pushed just outside the wall', () {
    final moved = model.standablePointNear(const Offset(46, 50));
    expect(moved, isNotNull);
    expect(moved!.dx, lessThan(45));
    expect((moved - const Offset(46, 50)).distance, lessThan(1.5));
  });

  test('a point just off the floor edge is pulled back onto the floor', () {
    final moved = model.standablePointNear(const Offset(-0.5, 50));
    expect(moved, isNotNull,
        reason: 'half a unit outside the painted floor is within reach');
    expect(model.receiverContains(moved!), isTrue);
    expect((moved - const Offset(-0.5, 50)).distance, lessThan(1.5));
  });

  test('a point in a wall cut into pieces leaves onto the floor, not a seam',
      () {
    // A one-unit-wide wall along the floor's west edge, cut every unit. The
    // nearest edges are the seams with the neighbouring pieces; the floor
    // is a little farther, to the east.
    final pieces = SvgHeightVisibility.fromJson(data(
      [
        for (var y = 0; y < 10; y++)
          wall('piece-$y', [rectangle(9, 40.0 + y, 10, 41.0 + y)])
      ],
      receiver: [_floor(rectangle(9.5, 0, 100, 100))],
    ));
    final moved = pieces.standablePointNear(const Offset(9.7, 45.1));
    expect(moved, isNotNull);
    expect(moved!.dx, greaterThan(10));
    expect(pieces.receiverContains(moved), isTrue);
  });

  test('a far open edge does not stop a near exit through a thin neighbour',
      () {
    // Thin walls cover both near sides of a 4 x 10 wall. The open ends are
    // 5 units away, out of reach; the way out is through a neighbour.
    final boxed = SvgHeightVisibility.fromJson(data(
      [
        wall('wide', [rectangle(0, 0, 4, 10)]),
        wall('west', [rectangle(-0.5, 0, 0, 10)]),
        wall('east', [rectangle(4, 0, 4.5, 10)]),
      ],
      receiver: [_floor(rectangle(-20, -20, 20, 30))],
    ));
    const start = Offset(1.9, 5);
    final moved = boxed.standablePointNear(start);
    expect(moved, isNotNull);
    expect((moved! - start).distance, lessThanOrEqualTo(2.5));
    expect(boxed.walls.where((w) => w.contains(moved)), isEmpty);
  });
}
