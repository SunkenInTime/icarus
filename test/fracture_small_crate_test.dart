import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Path;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  final fixture = jsonDecode(File('test/fixtures/fracture_small_crate_2026_09_14.json')
      .readAsStringSync()) as Map<String, dynamic>;
  Offset point(dynamic xy) =>
      Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble());
  for (final side in ['attack', 'defense']) {
    test('Fracture $side small crate uses its own source height', () {
      final directory =
          const bool.fromEnvironment('ICARUS_VERIFY_BUNDLED_GAMEPLAY')
              ? null
              : Platform.environment['ICARUS_FRACTURE_SMALL_CRATE_MODELS'];
      final path = directory == null
          ? 'assets/maps/fracture_svg_height_$side.json.gz'
          : '$directory/candidate-$side.json.gz';
      final model = SvgHeightVisibility.fromJson(jsonDecode(
          utf8.decode(gzip.decode(File(path).readAsBytesSync()))));
      for (final raw in fixture['cases'] as List) {
        final row = raw as Map<String, dynamic>;
        final origin = point(row['sides'][side]['origin']);
        final target = point(row['sides'][side]['target']);
        final label = row['id'] as String;
        final automatic = model.automaticSupportAt(origin);
        final defaultFloor = automatic?.surfaceElevationAt(origin) ??
            model.ground!.heightAt(origin);
        expect(defaultFloor,
            closeTo(row['expectedDefaultFloorMeters'] as num, .02),
            reason: '$label default uses the independently measured local floor');
        final selected = model.standingSupportAt(origin,
            savedEyeElevationCm: (row['expectedEyeMeters'] as num) * 100);
        final selectedFloor = selected?.surfaceElevationAt(origin) ??
            model.ground!.heightAt(origin);
        expect(selectedFloor, closeTo(row['expectedFloorMeters'] as num, .02),
            reason: '$label retains the independently measured saved level');
        expect(model.receiverContains(origin), isTrue, reason: label);
        expect(model.receiverContains(target), isTrue, reason: label);
        final delta = target - origin;
        final direction = math.atan2(delta.dy, delta.dx);
        final hit = model.castRay(
            origin: origin,
            directionRadians: direction,
            range: delta.distance,
            supportId: selected?.id);
        expect(hit == null, row['visible'], reason: '$label exact ray');
        final cone = model.cone(
            origin: origin,
            directionRadians: direction,
            apertureRadians: math.pi / 3,
            range: math.max(80, delta.distance + 5),
            supportId: selected?.id);
        expect((Path()..addPolygon(cone.polygon, true)).contains(target),
            row['visible'], reason: '$label production polygon');
      }
    });
  }
}
