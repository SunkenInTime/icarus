import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Path;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

SvgHeightVisibility fracture(String side) {
  final folder = const bool.fromEnvironment('ICARUS_VERIFY_BUNDLED_GAMEPLAY')
      ? null
      : Platform.environment['ICARUS_FRACTURE_WALL_MODELS'];
  final path = folder == null
      ? 'assets/maps/fracture_svg_height_$side.json.gz'
      : '$folder/candidate-$side.json.gz';
  return SvgHeightVisibility.fromJson(
      jsonDecode(utf8.decode(gzip.decode(File(path).readAsBytesSync()))));
}

Offset paired(String side, Offset p) =>
    side == 'attack' ? p : const Offset(459.738, 473) - p;

void main() {
  for (final side in ['attack', 'defense']) {
    test('Fracture $side free cone sees beyond the reported corridor ledge',
        () {
      final model = fracture(side);
      for (final shift in [-.3, 0.0, .3]) {
        final origin = paired(side, Offset(286.532634, 309.593025 + shift));
        // The user identified the free cone. This target is beyond the marked
        // y=281 ledge, on the corridor side of the A tunnel building.
        final target = paired(side, const Offset(326, 274));
        final delta = target - origin;
        final support = model.automaticSupportAt(origin)!;
        expect(support.surfaceElevationAt(origin), closeTo(8.91172, .02));
        expect(model.receiverContains(target), isTrue);
        expect(
            model.castRay(
                origin: origin,
                directionRadians: math.atan2(delta.dy, delta.dx),
                range: delta.distance,
                supportId: support.id),
            isNull);
        final cone = model.cone(
            origin: origin,
            directionRadians: math.atan2(delta.dy, delta.dx),
            apertureRadians: math.pi / 3,
            range: 120,
            supportId: support.id);
        expect(
            (Path()..addPolygon(cone.polygon, true)).contains(target), isTrue);
        for (final eye in [7.75, 13.0]) {
          expect(
              model.castRay(
                  origin: origin,
                  directionRadians: math.atan2(delta.dy, delta.dx),
                  range: delta.distance,
                  absoluteEyeElevationMeters: eye),
              isNotNull,
              reason: 'The lower wall and overhead structure remain solid');
        }
        final building = paired(side, const Offset(344, 274));
        final throughBuilding = building - origin;
        expect(
            model.castRay(
                origin: origin,
                directionRadians:
                    math.atan2(throughBuilding.dy, throughBuilding.dx),
                range: throughBuilding.distance,
                supportId: support.id),
            isNotNull,
            reason: 'The separate A tunnel building remains a blocker');
      }
    });
    test('Fracture $side corridor view extends when aimed along the corridor',
        () {
      final model = fracture(side);
      final origin = paired(side, const Offset(292.740602, 309.493985));
      final target = paired(side, const Offset(295, 275));
      final support = model.automaticSupportAt(origin);
      // Independent collision volumes 206 and 259 put this floor at 8.911 m.
      // The screenshot's visible aperture edge points toward the right wall.
      expect(support!.surfaceElevationAt(origin), closeTo(8.91172, .02));
      expect(model.receiverContains(target), isTrue);
      bool visible(double degrees) {
        final cone = model.cone(
            origin: origin,
            directionRadians:
                degrees * math.pi / 180 + (side == 'attack' ? 0 : math.pi),
            apertureRadians: math.pi / 3,
            range: 120,
            supportId: support.id);
        return (Path()..addPolygon(cone.polygon, true)).contains(target);
      }

      expect(visible(-40), isFalse);
      expect(visible(-90), isTrue);
      final wallTarget = paired(side, const Offset(294, 260));
      final delta = wallTarget - origin;
      final frameHit = model.castRay(
          origin: origin,
          directionRadians: math.atan2(delta.dy, delta.dx),
          range: delta.distance,
          supportId: support.id);
      expect(frameHit, isNotNull,
          reason:
              'The inset end frame still blocks farther along the corridor');
      expect(frameHit!.wallId,
          side == 'attack' ? 'p1-fill-7-local-41-0' : 'p1-fill-4-local-8');
    });
    test('Fracture $side upper ramp sees over the lower tunnel wall', () {
      final model = fracture(side);
      for (final shift in [-.5, 0.0, .5]) {
        final p = paired(side, Offset(151.038676, 225.311913 + shift));
        final target = paired(side, Offset(163.5, 205 + shift));
        final delta = target - p;
        final support = model.automaticSupportAt(p);
        expect(support!.surfaceElevationAt(p), greaterThan(5.5));
        expect(
            model.castRay(
                origin: p,
                directionRadians: math.atan2(delta.dy, delta.dx),
                range: delta.distance,
                supportId: support.id),
            isNull);
        expect(
            model.castRay(
                origin: p,
                directionRadians: math.atan2(delta.dy, delta.dx),
                range: delta.distance,
                absoluteEyeElevationMeters: 3),
            isNotNull,
            reason: 'The tunnel wall still blocks a lower standing eye');
      }
    });
    test('Fracture $side tower ledge retains a framed opening', () {
      final model = fracture(side);
      for (final shift in [-.5, 0.0, .5]) {
        final p = paired(side, Offset(54.959763, 174.003578 + shift));
        final target = paired(side, Offset(68, 174.003578 + shift));
        final delta = target - p;
        final support = model.automaticSupportAt(p);
        expect(support!.surfaceElevationAt(p), closeTo(10, .02));
        expect(
            model.castRay(
                origin: p,
                directionRadians: math.atan2(delta.dy, delta.dx),
                range: delta.distance,
                supportId: support.id),
            isNull);
        for (final eye in [9.5, 14.0]) {
          expect(
              model.castRay(
                  origin: p,
                  directionRadians: math.atan2(delta.dy, delta.dx),
                  range: delta.distance,
                  absoluteEyeElevationMeters: eye),
              isNotNull,
              reason: 'The solid base and header remain');
        }
      }
    });
    test('Fracture $side complete reactor blocks through plinth height cells',
        () {
      final model = fracture(side);
      for (final shift in [-.4, 0.0, .4]) {
        final p = paired(side, Offset(212.333803, 245.805908 + shift));
        for (final y in [217.0, 233.5, 240.2]) {
          final target = paired(side, Offset(232.5, y));
          final delta = target - p;
          final support = model.automaticSupportAt(p);
          expect(support!.surfaceElevationAt(p), closeTo(6.5, .02));
          final hit = model.castRay(
              origin: p,
              directionRadians: math.atan2(delta.dy, delta.dx),
              range: delta.distance,
              supportId: support.id);
          expect(hit, isNotNull,
              reason: 'Complete reactor wall toward $target');
          expect(hit!.distance, lessThan(delta.distance));
        }
      }
    });
  }
}
