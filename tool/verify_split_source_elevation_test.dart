import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  test('actual Split source elevations distinguish balcony and sewer levels',
      () async {
    const root = 'E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision';
    for (final side in ['attack', 'defense']) {
      final model = SvgHeightVisibility.fromJson(jsonDecode(
          await File('$root/split-svg-semantic-prototype-v18/split-$side.json')
              .readAsString()));
      Offset point(Offset p) =>
          side == 'attack' ? p : const Offset(466.1762, 473) - p;
      double angle(double a) => a + (side == 'attack' ? 0 : math.pi);
      final balcony = point(const Offset(122.2435, 204.3365));
      expect(model.ground!.heightAt(balcony), closeTo(5, 1e-6));
      final standing = model.cone(
          origin: balcony,
          directionRadians: angle(0),
          range: 65,
          apertureRadians: math.pi / 2);
      final selected = model.cone(
          origin: balcony,
          directionRadians: angle(0),
          range: 65,
          apertureRadians: math.pi / 2,
          supportId: 'b-balcony');
      expect(standing.eyeElevationMeters, closeTo(6.75, 1e-6));
      expect(standing.polygon, selected.polygon);
      for (final row in [
        (const Offset(98, 211), math.pi / 2, 4.75, 6.75, 5.0),
        (const Offset(378, 297), 0.0, 1.75, 4.75, 3.0000007152557373),
      ]) {
        final low = model.castRay(
            origin: point(row.$1),
            directionRadians: angle(row.$2),
            range: 10,
            absoluteEyeElevationMeters: row.$3);
        expect(low, isNotNull);
        final wall = model.walls.singleWhere((w) => w.id == low!.wallId);
        expect(wall.floorElevationMeters! + wall.bands.single.top,
            closeTo(row.$5, 1e-6));
        final high = model.castRay(
            origin: point(row.$1),
            directionRadians: angle(row.$2),
            range: 10,
            absoluteEyeElevationMeters: row.$4);
        expect(high?.wallId, isNot(low!.wallId));
      }
      expect(model.supports.length, 16);
      expect(model.walls.every((w) => w.floorElevationMeters != null), true);
      for (final support in model.supports) {
        expect(support.surfaceElevationMeters! - support.floorElevationMeters!,
            closeTo(support.heightAboveFloorMeters, 1e-6));
      }
    }
  });
}
