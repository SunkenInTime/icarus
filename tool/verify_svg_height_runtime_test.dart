import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  test('runtime-only data preserves reviewed Split cones exactly', () async {
    const root = 'E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision';
    var checked = 0;
    for (final side in ['attack', 'defense']) {
      Future<SvgHeightVisibility> load(String folder) async =>
          SvgHeightVisibility.fromJson(jsonDecode(
              await File('$root/$folder/split-$side.json').readAsString()));
      final reviewed = await load('split-svg-semantic-prototype-v12');
      final runtime = await load('split-svg-runtime-v4');
      final poses = jsonDecode(
          await File('$root/split-svg-semantic-prototype-v12/review-poses.json')
              .readAsString())['cases'] as List;
      for (final row in poses.where((row) => row['side'] == side)) {
        final origin = Offset((row['originSvg'][0] as num).toDouble(),
            (row['originSvg'][1] as num).toDouble());
        for (final direction in [0.0, pi / 2, pi, -pi / 2]) {
          SvgVisibilityCone query(SvgHeightVisibility model) => model.cone(
              origin: origin,
              directionRadians: direction,
              range: 100,
              apertureRadians: pi * 103 / 180,
              supportId: row['supportId'] as String?);
          final expected = query(reviewed), actual = query(runtime);
          expect(actual.polygon, expected.polygon);
          expect(actual.eyeHeightAboveFloorMeters,
              expected.eyeHeightAboveFloorMeters);
          expect(actual.stats.unknownWallHits, expected.stats.unknownWallHits);
          checked++;
        }
      }
    }
    expect(checked, 364);
  });
}
