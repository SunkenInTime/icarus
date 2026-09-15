import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Path;
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  final fixture = jsonDecode(
      File('test/fixtures/remaining_ownership_sightlines_2026_09_15.json')
          .readAsStringSync());
  final root = const bool.fromEnvironment('ICARUS_VERIFY_BUNDLED_GAMEPLAY')
      ? null
      : Platform.environment['ICARUS_REMAINING_OWNERSHIP_MODELS'];
  for (final row in fixture['cases']) {
    for (final side in ['attack', 'defense']) {
      test('${row['id']} $side', () {
        final file = root == null || row['retainedBaseline'] == true
            ? 'assets/maps/${row['map']}_svg_height_$side.json.gz'
            : '$root/${row['map']}/candidate-$side.json.gz';
        final model = SvgHeightVisibility.fromJson(
            jsonDecode(utf8.decode(gzip.decode(File(file).readAsBytesSync()))));
        Offset xy(dynamic p) =>
            Offset((p[0] as num).toDouble(), (p[1] as num).toDouble());
        final origin = xy(row['sides'][side]['origin']);
        final target = xy(row['sides'][side]['target']);
        final eye = (row['eyeMeters'] as num).toDouble();
        if (row['floorMeters'] != null) {
          expect(model.receiverContains(origin), isTrue);
          expect(model.receiverContains(target), isTrue);
          final support = model.automaticSupportAt(origin);
          final selectedEye = support == null
              ? model.groundEyeElevationAt(origin)
              : support.surfaceElevationAt(origin)! +
                  model.defaultCameraHeightMeters;
          expect(selectedEye, closeTo(eye, .02),
              reason: 'Independent physical source floor');
        }
        final delta = target - origin;
        final direction = math.atan2(delta.dy, delta.dx);
        final hit = model.castRay(
            origin: origin,
            directionRadians: direction,
            range: delta.distance,
            absoluteEyeElevationMeters: eye);
        expect(hit != null, row['expectedBlocked'],
            reason: '${row['id']} ${hit?.wallId}');
        final cone = model.cone(
            origin: origin,
            directionRadians: direction,
            apertureRadians: math.pi / 3,
            range: delta.distance + 1,
            absoluteEyeElevationMeters: eye);
        final visible = cone.visibilityPath?.contains(target) ??
            (Path()..addPolygon(cone.polygon, true)).contains(target);
        expect(visible, !(row['expectedBlocked'] as bool));
      });
    }
  }
}
