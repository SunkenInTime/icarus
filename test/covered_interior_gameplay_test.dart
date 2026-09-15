import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Path;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

Offset point(Map sides, String side) {
  final xy = sides[side] as List;
  return Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble());
}

void main() {
  final fixture = jsonDecode(File('test/fixtures/covered_interior_gameplay.json')
      .readAsStringSync());
  for (final entry in (fixture['maps'] as Map).entries) {
    final name = entry.key as String;
    final cases = entry.value as Map;
    for (final side in ['attack', 'defense']) {
      test('$name $side covered interiors retain their gameplay floor and walls',
          () {
        final override = const bool.fromEnvironment('ICARUS_VERIFY_BUNDLED_GAMEPLAY')
            ? null : Platform.environment['ICARUS_COVERED_INTERIOR_MODELS'];
        final asset = override == null
            ? 'assets/maps/${name}_svg_height_$side.json.gz'
            : '$override/$name/candidate-$side.json.gz';
        final model = SvgHeightVisibility.fromJson(jsonDecode(
            utf8.decode(gzip.decode(File(asset).readAsBytesSync()))));
        for (final row in cases['poses'] as List) {
          final origin = point(row['svg'], side);
          expect(model.receiverContains(origin), isTrue);
          final cone = model.cone(origin: origin, directionRadians: 0,
              apertureRadians: math.pi / 3, range: 30,
              supportId: model.automaticSupportAt(origin)?.id);
          expect(cone.eyeElevationMeters! - model.defaultCameraHeightMeters,
              closeTo((row['expectedFloorMeters'] as num).toDouble(), .02),
              reason: '${row['id']} must use the represented interior floor');
          final roof = row['savedRoofFloorMeters'] as num?;
          if (roof != null) {
            final saved = model.standingSupportAt(origin,
                savedEyeElevationCm:
                    (roof.toDouble() + model.defaultCameraHeightMeters) * 100);
            expect(saved, isNotNull,
                reason: '${row['id']} must retain an explicit roof selection');
            final upperCone = model.cone(origin: origin, directionRadians: 0,
                apertureRadians: math.pi / 3, range: 30, supportId: saved!.id);
            expect(upperCone.eyeElevationMeters! - model.defaultCameraHeightMeters,
                closeTo(roof.toDouble(), .02),
                reason: '${row['id']} must preserve the saved upper level');
          }
        }
        for (final row in cases['rays'] as List) {
          final origin = point(row['origin'], side);
          final target = point(row['target'], side);
          final delta = target - origin;
          final direction = math.atan2(delta.dy, delta.dx);
          final supportId = model.automaticSupportAt(origin)?.id;
          expect(model.receiverContains(origin), isTrue);
          expect(model.receiverContains(target), isTrue);
          final hit = model.castRay(origin: origin, directionRadians: direction,
              range: delta.distance, supportId: supportId);
          expect(hit != null, row['blocked'], reason: row['id']);
          final cone = model.cone(origin: origin, directionRadians: direction,
              apertureRadians: math.pi / 3, range: delta.distance + 2,
              supportId: supportId);
          expect(cone.eyeElevationMeters! - model.defaultCameraHeightMeters,
              closeTo((row['expectedFloorMeters'] as num).toDouble(), .02));
          expect((Path()..addPolygon(cone.polygon, true)).contains(target),
              !(row['blocked'] as bool), reason: row['id']);
        }
      });
    }
  }
}
