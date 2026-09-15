import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  test('source prop bounds preserve tall cover and clear low cover', () async {
    const root = 'E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision';
    final measurements = jsonDecode(await File(
            '$root/split-svg-semantic-prototype-v9/prop-height-batch.json')
        .readAsString()) as List;
    final poses = jsonDecode(
        await File('$root/split-svg-semantic-prototype-v9/review-poses.json')
            .readAsString())['cases'] as List;
    final covered = <String>{};
    var checked = 0;
    for (final side in ['attack', 'defense']) {
      Future<SvgHeightVisibility> load(int v) async =>
          SvgHeightVisibility.fromJson(jsonDecode(await File(
                  '$root/split-svg-semantic-prototype-v$v/split-$side.json')
              .readAsString()));
      final before = await load(8), after = await load(12);
      for (final measurement in measurements) {
        final id = measurement['id'] as String;
        final wallId = measurement['wallsBySide'][side] as String;
        final height =
            (measurement['heightUpperBoundMeters'] as num).toDouble();
        for (final row in poses.where((p) =>
            p['side'] == side && (p['id'] as String).startsWith('$id-'))) {
          final origin = Offset((row['originSvg'][0] as num).toDouble(),
              (row['originSvg'][1] as num).toDouble());
          SvgVisibilityHit? query(SvgHeightVisibility model, double camera) =>
              model.castRay(
                  origin: origin,
                  directionRadians: (row['directionRadians'] as num).toDouble(),
                  range: 60,
                  cameraHeightMeters: camera);
          final old = query(before, 1.75);
          if (old?.wallId != wallId)
            continue; // Another wall occludes this approach.
          final standing = query(after, 1.75);
          if (height > 1.75) {
            expect(standing?.wallId, wallId);
            expect(standing?.point, old?.point);
          } else {
            expect(standing?.wallId, isNot(wallId));
          }
          expect(query(after, height + .1)?.wallId, isNot(wallId));
          covered.add('$id/$side');
          checked++;
        }
      }
    }
    expect(covered.length, 12);
    expect(checked, greaterThanOrEqualTo(12));
    print('$checked clear-approach checks across all six props and both sides');
  });
}
