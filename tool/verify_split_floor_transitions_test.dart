import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  test('A Ramp and Mailroom sightlines cross floor transitions both ways',
      () async {
    const root = 'E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision';
    final configs = jsonDecode(await File(
            '$root/split-svg-semantic-prototype-v7/floor-transition-corrections.json')
        .readAsString()) as List;
    for (final side in ['attack', 'defense']) {
      Future<SvgHeightVisibility> load(int v) async =>
          SvgHeightVisibility.fromJson(jsonDecode(await File(
                  '$root/split-svg-semantic-prototype-v$v/split-$side.json')
              .readAsString()));
      final before = await load(6), after = await load(12);
      for (final row in configs) {
        var center = Offset((row['center'][0] as num).toDouble(),
            (row['center'][1] as num).toDouble());
        if (side == 'defense') center = const Offset(466.1762, 473) - center;
        for (final sign in [-1, 1]) {
          // Include several positions across the span, not only its midpoint.
          for (final shift in [-2.0, 0.0, 2.0]) {
            final origin = center + Offset(shift, sign * 3.0);
            SvgVisibilityHit? query(SvgHeightVisibility model) => model.castRay(
                origin: origin, directionRadians: -sign * pi / 2, range: 6);
            expect(query(before)?.wallId, row['${side}Wall']);
            expect(query(after), isNull);
          }
        }
      }
    }
  });
}
