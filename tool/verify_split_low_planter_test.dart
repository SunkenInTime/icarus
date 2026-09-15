import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  test('standing view clears A Lobby planter on both SVG sides', () async {
    const root = 'E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision';
    for (final side in ['attack', 'defense']) {
      Future<SvgHeightVisibility> load(int version) async =>
          SvgHeightVisibility.fromJson(jsonDecode(await File(
                  '$root/split-svg-semantic-prototype-v$version/split-$side.json')
              .readAsString()));
      final before = await load(7), after = await load(12);
      final attack = side == 'attack';
      final origin = attack
          ? const Offset(421.0195, 352.054)
          : const Offset(45.1567, 120.946);
      SvgVisibilityHit? query(SvgHeightVisibility model, double camera) =>
          model.castRay(
              origin: origin,
              directionRadians: attack ? pi / 2 : -pi / 2,
              range: 5,
              cameraHeightMeters: camera);
      expect(query(before, 1.75), isNotNull);
      expect(query(after, 1.75), isNull);
      // The structure is still solid below its measured height. This is a
      // diagnostic ray, not support for crouching in the product.
      expect(query(after, .5), isNotNull);
    }
  });
}
