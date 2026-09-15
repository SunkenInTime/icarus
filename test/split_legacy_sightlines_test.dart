import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  final candidate =
      Platform.environment['ICARUS_VERIFY_BUNDLED_GAMEPLAY'] == 'true'
          ? null
          : Platform.environment['ICARUS_REGIONAL_CANDIDATE'];
  File assetFor(String side) => File(candidate == null
      ? 'assets/maps/split_svg_height_$side.json.gz'
      : '$candidate/candidate-$side.json.gz');
  final fixture = jsonDecode(
      File('test/fixtures/split_legacy_sightlines.json').readAsStringSync());
  for (final side in ['attack', 'defense']) {
    for (final box in fixture['boxes']) {
      test('Split $side preserves measured ${box['id']} cover and selected top',
          () {
        final model = SvgHeightVisibility.fromJson(jsonDecode(
            utf8.decode(gzip.decode(assetFor(side).readAsBytesSync()))));
        for (final pose in box['poses']) {
          if (pose['side'] != side) continue;
          final origin = Offset((pose['originSvg'][0] as num).toDouble(),
              (pose['originSvg'][1] as num).toDouble());
          expect(model.receiverContains(origin), isTrue);
          final supportId = pose['supportId'] as String?;
          if (supportId == null) {
            expect(model.ground!.heightAt(origin),
                closeTo((box['floorMeters'] as num).toDouble(), .02));
          } else {
            // Source evidence establishes an exposed physical top. This tests
            // explicit selection and makes no claim about how players reach it.
            final support =
                model.supports.singleWhere((s) => s.id == supportId);
            expect(support.contains(origin), isTrue);
            expect(support.surfaceElevationAt(origin),
                closeTo((box['topMeters'] as num).toDouble(), .00001));
          }
          final direction = (pose['directionRadians'] as num).toDouble();
          final hit = model.castRay(
              origin: origin,
              directionRadians: direction,
              range: 6,
              supportId: supportId);
          if (supportId == null) {
            expect(hit, isNotNull,
                reason: 'Ground eye must hit solid box cover');
            expect(box['wallsBySide'][side], contains(hit!.wallId));
          } else {
            expect(hit, isNull,
                reason: 'Selected exposed top clears its own edge');
            // Returning the eye to the independently measured adjacent floor
            // must restore occlusion at the same authored box edge.
            expect(
                model.castRay(
                    origin: origin,
                    directionRadians: direction,
                    range: 6,
                    absoluteEyeElevationMeters:
                        (box['floorMeters'] as num).toDouble() + 1.75),
                isNotNull);
          }
        }
      });
    }
    test('Split $side retains reviewed floor transitions and low planter', () {
      final model = SvgHeightVisibility.fromJson(jsonDecode(
          utf8.decode(gzip.decode(assetFor(side).readAsBytesSync()))));
      for (final row in fixture['floorTransitions']) {
        var center = Offset((row['center'][0] as num).toDouble(),
            (row['center'][1] as num).toDouble());
        if (side == 'defense') center = const Offset(466.1762, 473) - center;
        for (final sign in [-1, 1]) {
          for (final shift in [-2.0, 0.0, 2.0]) {
            final origin = center + Offset(shift, sign * 3.0);
            expect(model.receiverContains(origin), isTrue);
            expect(
                model.castRay(
                    origin: origin,
                    directionRadians: -sign * math.pi / 2,
                    range: 6),
                isNull,
                reason: '${row['id']} remains a floor transition');
          }
        }
      }
      final origin = side == 'attack'
          ? const Offset(421.0195, 352.054)
          : const Offset(45.1567, 120.946);
      expect(model.receiverContains(origin), isTrue);
      SvgVisibilityHit? cast(double camera) => model.castRay(
          origin: origin,
          directionRadians: side == 'attack' ? math.pi / 2 : -math.pi / 2,
          range: 5,
          cameraHeightMeters: camera);
      expect(cast(1.75), isNull, reason: 'Standing eye clears the low planter');
      expect(cast(.5), isNotNull, reason: 'The planter retains a solid base');
    });
  }
}
