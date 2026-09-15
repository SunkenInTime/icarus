import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Path;
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  final fixture = jsonDecode(
      File('test/fixtures/all_map_confirmed_walls_2026_09_14.json')
          .readAsStringSync());
  final bundled = const bool.fromEnvironment('ICARUS_VERIFY_BUNDLED_GAMEPLAY');
  final root =
      bundled ? null : Platform.environment['ICARUS_CONFIRMED_WALL_MODELS'];
  for (final row in fixture['cases']) {
    for (final side in ['attack', 'defense']) {
      test('${row['map']} $side ${row['id']}', () {
        final path = root == null
            ? 'assets/maps/${row['map']}_svg_height_$side.json.gz'
            : '$root/${row['map']}/candidate-$side.json.gz';
        final model = SvgHeightVisibility.fromJson(
            jsonDecode(utf8.decode(gzip.decode(File(path).readAsBytesSync()))));
        final data = row['sides'][side];
        final origin = Offset((data['origin'][0] as num).toDouble(),
            (data['origin'][1] as num).toDouble());
        final target = Offset((data['target'][0] as num).toDouble(),
            (data['target'][1] as num).toDouble());
        final delta = target - origin;
        if (row['expectedFloorMeters'] != null) {
          expect(model.receiverContains(origin), isTrue);
          expect(model.receiverContains(target), isTrue);
          if (row['verifyAutomaticFloor'] == true) {
            final support = model.automaticSupportAt(origin);
            expect(support, isNotNull);
            expect(support!.surfaceElevationAt(origin),
                closeTo((row['expectedFloorMeters'] as num).toDouble(), .02));
          }
        }
        final hit = model.castRay(
            origin: origin,
            directionRadians: math.atan2(delta.dy, delta.dx),
            range: delta.distance,
            absoluteEyeElevationMeters:
                (row['absoluteEyeMeters'] as num).toDouble());
        expect(hit != null, row['expectedBlocked'], reason: row['id']);
        final cone = model.cone(
            origin: origin,
            directionRadians: math.atan2(delta.dy, delta.dx),
            apertureRadians: .08,
            range: delta.distance + .2,
            absoluteEyeElevationMeters:
                (row['absoluteEyeMeters'] as num).toDouble());
        final contains =
            (Path()..addPolygon(cone.polygon, true)).contains(target);
        expect(contains, !(row['expectedBlocked'] as bool),
            reason: '${row['id']} cone');
      });
    }
  }
  for (final row in fixture['floorControls'] ?? []) {
    for (final side in ['attack', 'defense']) {
      test('${row['map']} $side ${row['id']}', () {
        final path = root == null
            ? 'assets/maps/${row['map']}_svg_height_$side.json.gz'
            : '$root/${row['map']}/candidate-$side.json.gz';
        final model = SvgHeightVisibility.fromJson(
            jsonDecode(utf8.decode(gzip.decode(File(path).readAsBytesSync()))));
        final xy = row['sides'][side];
        final origin =
            Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble());
        expect(model.receiverContains(origin), isTrue);
        final support = model.automaticSupportAt(origin);
        final floor = support?.surfaceElevationAt(origin) ??
            model.ground!.heightAt(origin);
        expect(floor, closeTo(row['expectedFloorMeters'] as num, .02));
      });
    }
  }
}
