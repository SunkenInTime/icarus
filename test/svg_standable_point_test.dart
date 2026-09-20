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
}
