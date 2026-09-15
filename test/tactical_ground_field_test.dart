import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/tactical_ground_field.dart';

Map<String, dynamic> field(List<num> vertices, List<int> triangles) => {
      'version': 1,
      'coordinateSpace': 'native-meters',
      'vertices': vertices,
      'triangles': triangles,
    };

void main() {
  test(
      'ramp interpolation preserves standing clearance and raised observer height',
      () {
    final ground = TacticalGroundField.fromJson(
        field([0, 0, 2, 10, 0, 6, 10, 4, 6, 0, 4, 2], [0, 1, 2, 0, 2, 3]));
    expect(ground.heightAt(const Offset(5, 2)), closeTo(4, 1e-10));
    expect(5.75 - ground.heightAt(const Offset(5, 2))!, closeTo(1.75, 1e-10));
    expect(8.75 - ground.heightAt(const Offset(5, 2))!, closeTo(4.75, 1e-10));
    expect(ground.heightAt(const Offset(11, 2)), isNull);
  });

  test('shared edges agree under either winding and negative coordinates', () {
    final ground = TacticalGroundField.fromJson(
        field([-8, -8, 0, 0, -8, 4, 0, 0, 4, -8, 0, 0], [2, 1, 0, 0, 2, 3]));
    for (var i = 0; i <= 8; i++) {
      expect(ground.heightAt(Offset(-8 + i.toDouble(), -8 + i.toDouble())),
          closeTo(i / 2, 1e-10));
    }
  });

  test(
      'stacked floor ambiguity is rejected instead of choosing the highest floor',
      () {
    final ground = TacticalGroundField.fromJson(field(
        [0, 0, 0, 4, 0, 0, 0, 4, 0, 0, 0, 3, 4, 0, 3, 0, 4, 3],
        [0, 1, 2, 3, 4, 5]));
    expect(() => ground.heightAt(const Offset(1, 1)), throwsFormatException);
  });

  test('invalid field data fails before use', () {
    for (final json in [
      field([0, 0, double.nan, 4, 0, 0, 0, 4, 0], [0, 1, 2]),
      field([0, 0, 0, 4, 0, 0, 0, 4, 0], [0, 1, 3]),
      field([0, 0, 0, 4, 0, 0, 8, 0, 0], [0, 1, 2]),
    ]) {
      expect(() => TacticalGroundField.fromJson(json), throwsFormatException);
    }
  });
}
