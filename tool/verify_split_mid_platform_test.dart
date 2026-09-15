import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  test('Mid box sees across the connected platform edge on both sides', () async {
    const root = 'E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision';
    for (final side in ['attack', 'defense']) {
      Future<SvgHeightVisibility> load(int version) async =>
          SvgHeightVisibility.fromJson(jsonDecode(await File(
                  '$root/split-svg-semantic-prototype-v$version/split-$side.json')
              .readAsString()));
      final before = await load(5), after = await load(12);
      final attack = side == 'attack';
      final top = attack
          ? const Offset(236.278, 243.4115)
          : const Offset(229.8985, 229.5885);
      final direction = attack ? pi : 0.0;
      SvgVisibilityHit? topRay(SvgHeightVisibility model) => model.castRay(
          origin: top,
          directionRadians: direction,
          range: 18,
          supportId: 'mid-box7414');
      expect(topRay(before)?.wallId,
          attack ? 'p16-unknown-1' : 'p16-unknown-2');
      expect(topRay(after), isNull);
      // Connected ramp ground is continuous even without selecting box support.
      expect(
          after.castRay(
              origin: attack
                  ? const Offset(229, 243.4115)
                  : const Offset(237.1762, 229.5885),
              directionRadians: direction,
              range: 8),
          isNull);
    }
  });
}
