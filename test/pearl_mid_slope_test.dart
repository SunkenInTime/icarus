import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  final fixture = jsonDecode(
      File('test/fixtures/pearl_mid_slope_2026_09_18.json').readAsStringSync());
  Offset point(List p) =>
      Offset((p[0] as num).toDouble(), (p[1] as num).toDouble());
  for (final side in ['attack', 'defense']) {
    test('Pearl $side Mid slope has a standing floor and an open view', () {
      final folder = Platform.environment['ICARUS_PEARL_SLOPE_BASELINE'];
      final path = folder == null
          ? 'assets/maps/pearl_svg_height_$side.json.gz'
          : '$folder/reported-$side.json.gz';
      final model = SvgHeightVisibility.fromJson(
          jsonDecode(utf8.decode(gzip.decode(File(path).readAsBytesSync()))));
      for (final row in fixture['cases']) {
        final origin = point(row['svg'][side]);
        final support = model.automaticSupportAt(origin);
        expect(support, isNotNull,
            reason:
                'The physical slope cannot fall back to the ground inside its solid body.');
        expect(support!.surfaceElevationAt(origin)! + 1.75,
            closeTo(row['expectedEyeMeters'], .0001));
        final cone = model.cone(
            origin: origin,
            directionRadians:
                row['directionAttack'] + (side == 'attack' ? 0 : math.pi),
            apertureRadians: 103 * math.pi / 180,
            range: 100.326,
            supportId: support.id);
        final visible =
            cone.visibilityPath ?? (Path()..addPolygon(cone.polygon, true));
        for (final target in row['visibilityTargets']) {
          final p = point(target['svg'][side]);
          expect(model.receiverContains(p), isTrue);
          expect(visible.contains(p), target['visible'],
              reason: '${row['id']} target $p');
        }
        final savedGround = model.groundEyeElevationAt(origin)!;
        expect(model.isGroundEyeElevation(origin, savedGround * 100), isTrue);
        expect(
            model.standingSupportAt(origin,
                savedEyeElevationCm: savedGround * 100),
            isNull,
            reason: 'Do not rewrite a saved explicit ground selection.');
      }
    });
  }
}
