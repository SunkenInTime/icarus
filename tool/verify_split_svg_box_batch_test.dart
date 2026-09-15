import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('measured B boxes block beside them and clear from their exposed tops',
      () async {
    final folder = Platform.environment['ICARUS_SVG_HEIGHT_INPUT'] ??
        'E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision/'
            'split-svg-semantic-prototype-v3';
    final batch = jsonDecode(
        await File('$folder/annotation-extension.json').readAsString()) as Map;
    var checked = 0;
    for (final side in ['attack', 'defense']) {
      final model = SvgHeightVisibility.fromJson(
          jsonDecode(await File('$folder/split-$side.json').readAsString()));
      for (final row in batch['reviewCases'] as List) {
        if (row['side'] != side) continue;
        final origin = Offset((row['originSvg'][0] as num).toDouble(),
            (row['originSvg'][1] as num).toDouble());
        final direction = (row['directionRadians'] as num).toDouble();
        final supportId = row['supportId'] as String?;
        final hit = model.castRay(
            origin: origin,
            directionRadians: direction,
            range: 5,
            supportId: supportId);
        final annotation = (batch['annotations'] as List)
            .singleWhere((a) => a['id'] == row['sourceEvidence']['annotation']);
        if (supportId == null) {
          expect(hit, isNotNull);
          expect(annotation['wallsBySide'][side], contains(hit!.wallId));
          // Both literal SVG sides place the facing 1-unit stroke edge
          // 3.5 units from these preserved ground reference positions.
          expect(hit.distance, closeTo(3.5, 1e-9));
          expect(hit.unknownHeight, isFalse);
        } else {
          expect(hit, isNull);
          final cone = model.cone(
              origin: origin,
              directionRadians: direction,
              range: 5,
              apertureRadians: 1.2,
              supportId: supportId);
          expect(
              cone.eyeHeightAboveFloorMeters,
              closeTo(
                  (annotation['supportsBySide'][side]['heightAboveFloorMeters']
                          as num) +
                      1.75,
                  1e-12));
          expect(cone.eyeHeightAboveFloorMeters,
              greaterThan((annotation['bands'][0][1] as num).toDouble()));
          expect(
              model.supportsAt(origin).map((s) => s.id), contains(supportId));
        }
        checked++;
      }
    }
    expect(checked, 8);
  });
}
