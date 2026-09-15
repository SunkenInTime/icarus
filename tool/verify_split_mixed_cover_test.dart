import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  test('low cover clears but its taller neighbour owns the shared painted edge',
      () async {
    const root = 'E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision';
    final report = jsonDecode(await File(
            '$root/split-svg-semantic-prototype-v12/mixed-cover-batch.json')
        .readAsString()) as List;
    final poses = jsonDecode(
        await File('$root/split-svg-semantic-prototype-v12/review-poses.json')
            .readAsString())['cases'] as List;
    for (final side in ['attack', 'defense']) {
      final model = SvgHeightVisibility.fromJson(jsonDecode(
          await File('$root/split-svg-semantic-prototype-v12/split-$side.json')
              .readAsString()));
      for (final row in report) {
        final info = row['sides'][side];
        final pose =
            poses.singleWhere((p) => p['id'] == '${row['id']}-shared-$side');
        final origin = Offset((pose['originSvg'][0] as num).toDouble(),
            (pose['originSvg'][1] as num).toDouble());
        final hit = model.castRay(
            origin: origin,
            directionRadians: (pose['directionRadians'] as num).toDouble(),
            range: 65);
        expect(hit, isNotNull);
        expect(hit!.wallId, contains('${info['parentWallId']}-high-'));
        final coordinate = info['axis'] == 0 ? hit.point.dx : hit.point.dy;
        expect(coordinate,
            closeTo((info['splitAtPaintedEdge'] as num).toDouble(), 1e-8));
        expect(hit.unknownHeight, isFalse);
      }
    }
  });
}
