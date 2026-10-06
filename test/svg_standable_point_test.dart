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

  // Found in review: the floor edge search reads rows of edges outward from
  // the point and stops early. It must pick the edge reading every edge
  // would, even where rounding makes far edges tie, and must not trip over a
  // footprint too tall to split into rows.
  test('the nearest floor edge is the one a full scan finds, at any scale', () {
    final huge = SvgHeightVisibility.fromJson(data(
      [],
      receiver: [
        for (final (i, ring) in [
          [-10.0, 3e16, 10.0, 3e16, 10.0, 3e16 + 100, -10.0, 3e16 + 100],
          [2e16, 0.0, 2e16 + 100, 0.0, 2e16 + 100, 2e16, 2e16, 2e16],
          [
            1000.0,
            4.096e19 - 10000,
            2000.0,
            4.096e19 - 10000,
            2000.0,
            4.096e19,
            1000.0,
            4.096e19
          ],
        ].indexed)
          {
            'id': 'floor-$i',
            'rings': [ring],
            'fillRule': 'nonzero'
          }
      ],
    ));
    expect(
        huge.standablePointNear(const Offset(0, 1e16 - 2), maxDistance: 2e16),
        const Offset(0, 3e16));
    final tall = SvgHeightVisibility.fromJson(data(
      [],
      receiver: [
        _floor([10, -1e308, 10, 1e308, 11, 1e308, 11, -1e308])
      ],
    ));
    expect(tall.standablePointNear(Offset.zero), isNull);
  });

  test('a point already on the floor is returned as it is', () {
    expect(
        model.standablePointNear(const Offset(20, 20)), const Offset(20, 20));
  });

  test('a point within the ink margin below a wall is pushed out', () {
    // 54.96 is 0.02 below the wall, inside the 0.05 margin that counts as
    // ink, and in the next unit row down from the wall's bottom edge.
    final low = SvgHeightVisibility.fromJson(data(
      [
        wall('pillar', [rectangle(45, 45, 55, 54.94)])
      ],
      receiver: [_floor(rectangle(0, 0, 100, 100))],
    ));
    final moved = low.standablePointNear(const Offset(50, 54.96));
    expect(moved, isNotNull);
    expect(moved!.dy, greaterThan(54.99));
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

  test('a slit between two walls is not somewhere to stand', () {
    // Two walls drawn 0.02 apart, as Breeze attack has them at y 107.6.
    final slit = SvgHeightVisibility.fromJson(data(
      [
        wall('north', [rectangle(0, 9, 100, 10)]),
        wall('south', [rectangle(0, 10.02, 100, 11)]),
      ],
      receiver: [_floor(rectangle(0, 0, 100, 100))],
    ));
    final moved = slit.standablePointNear(const Offset(50, 10.01))!;
    expect(moved.dy < 9 || moved.dy > 11, isTrue,
        reason: 'stepped out to open floor, not left in the slit: $moved');
  });
}
