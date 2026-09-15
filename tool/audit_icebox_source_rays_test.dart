import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  test('compare source ray candidates with production SVG ray behavior', () {
    final dir = Platform.environment['ICARUS_ICEBOX_AUDIT']!;
    final model = SvgHeightVisibility.fromJson(
        jsonDecode(File('$dir/models/icebox-attack.json').readAsStringSync()));
    final source = jsonDecode(File('$dir/support-sightline-discrepancies.json')
        .readAsStringSync()) as Map<String, dynamic>;
    final records = <Map<String, dynamic>>[];
    for (final raw in source['records']) {
      final row = Map<String, dynamic>.from(raw);
      final xy = row['originSvg'] as List;
      final hit = model.castRay(
          origin: Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble()),
          directionRadians: (row['directionRadians'] as num).toDouble(),
          range: 40,
          supportId: row['supportId'] as String);
      row['productionHit'] = hit?.distance ?? 40;
      row['productionWallId'] = hit?.wallId;
      row['productionDifferenceSvg'] =
          (row['sourceMeshHit'] as num) - (hit?.distance ?? 40);
      records.add(row);
    }
    File('$dir/production-source-ray-comparison.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(records));
    expect(records, hasLength(880));
  });
}
