import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  for (final side in ['attack', 'defense']) {
    test('Pearl $side industrial facade keeps its low base opaque', () {
      final folder =
          const bool.fromEnvironment('ICARUS_VERIFY_BUNDLED_GAMEPLAY')
              ? null
              : Platform.environment['ICARUS_PEARL_WALL_MODELS'];
      final path = folder == null
          ? 'assets/maps/pearl_svg_height_$side.json.gz'
          : '$folder/candidate-$side.json.gz';
      final model = SvgHeightVisibility.fromJson(
          jsonDecode(utf8.decode(gzip.decode(File(path).readAsBytesSync()))));
      Offset point(double x, double y) => side == 'attack'
          ? Offset(x, y)
          : const Offset(468.6677, 473) - Offset(x, y);
      // Collision domain volume-38-0, top faces 10/11, independently supplies
      // this 6 m floor. The complete local wall reaches 12.43877 m.
      for (final row in [
        [
          461.02012624654776,
          261.92666879757314,
          470.2173226836635,
          261.92666879757314
        ],
        [461.02012624654776, 260.08722951015, 470.2173226836635, 263.766108085],
      ]) {
        final origin = point(row[0], row[1]);
        final target = point(row[2], row[3]);
        final support = model.automaticSupportAt(origin);
        final floor = support?.surfaceElevationAt(origin) ??
            model.ground!.heightAt(origin);
        expect(floor, closeTo(6, .02));
        final delta = target - origin;
        final hit = model.castRay(
            origin: origin,
            directionRadians: math.atan2(delta.dy, delta.dx),
            range: delta.distance,
            supportId: support?.id);
        expect(hit, isNotNull);
        expect(hit!.distance, lessThan(delta.distance));
      }
    });
  }
}
