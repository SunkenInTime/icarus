import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Path;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  for (final side in ['attack', 'defense']) {
    test('Haven $side keeps Heaven stable across the reported ceiling strip',
        () {
      final folder =
          const bool.fromEnvironment('ICARUS_VERIFY_BUNDLED_GAMEPLAY')
              ? null
              : Platform.environment['ICARUS_HAVEN_MODELS'];
      final path = folder == null
          ? 'assets/maps/haven_svg_height_$side.json.gz'
          : '$folder/haven-$side.json.gz';
      final model = SvgHeightVisibility.fromJson(
          jsonDecode(utf8.decode(gzip.decode(File(path).readAsBytesSync()))));
      // The two authored Haven sides are the frozen source transform [-x + 392.991, -y + 473].
      Offset point(double x, double y) =>
          side == 'attack' ? Offset(x, y) : Offset(392.991 - x, 473 - y);
      for (var x = 347.0; x <= 357.5; x += .5) {
        for (var y = 133.0; y <= 138.5; y += .25) {
          final origin = point(x, y);
          final support = model.automaticSupportAt(origin);
          expect(
              support?.surfaceElevationAt(origin) ??
                  model.ground!.heightAt(origin),
              closeTo(9, .02),
              reason: '$side $origin');
          final target = point(340, y);
          final delta = target - origin;
          expect(
              model.castRay(
                  origin: origin,
                  directionRadians: math.atan2(delta.dy, delta.dx),
                  range: delta.distance,
                  supportId: support?.id),
              isNotNull,
              reason: 'The outer tower wall must block at $origin');
        }
      }
      final origin = point(198.18, 256.97);
      final target = point(193.33, 320.61);
      final delta = target - origin;
      final support = model.automaticSupportAt(origin);
      final cone = model.cone(
          origin: origin,
          directionRadians: math.atan2(delta.dy, delta.dx),
          range: 100,
          apertureRadians: math.pi / 2,
          supportId: support?.id);
      expect(cone.visibilityPath, isNull,
          reason:
              'The tactical opening must not create a separate floor patch.');
      expect((Path()..addPolygon(cone.polygon, true)).contains(target), isTrue);
    });
  }
}
