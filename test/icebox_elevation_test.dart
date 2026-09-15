import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  final candidatePath = Platform.environment['ICARUS_REGIONAL_CANDIDATE'];
  SvgHeightVisibility load(String side) => SvgHeightVisibility.fromJson(
      jsonDecode(utf8.decode(gzip.decode(File(candidatePath == null
              ? 'assets/maps/icebox_svg_height_$side.json.gz'
              : '$candidatePath/candidate-$side.json.gz')
          .readAsBytesSync()))) as Map<String, dynamic>);

  for (final side in ['attack', 'defense']) {
    final model = load(side);
    final attack = side == 'attack';
    Offset point(double x, double y) =>
        attack ? Offset(x, y) : Offset(387.459 - x, 473 - y);
    double direction(double angle) => angle + (attack ? 0 : math.pi);
    SvgHeightSupport physicalSupport(double x, double y, double floor) {
      final support = model.supportForAbsoluteEyeElevation(
          point(x, y), (floor + 1.75) * 100);
      expect(support, isNotNull, reason: 'Physical floor $floor m at [$x,$y]');
      return support!;
    }

    final tubeEvidence = jsonDecode(
        File('test/fixtures/icebox_tube_source_levels.json')
            .readAsStringSync()) as Map<String, dynamic>;
    double tubeFloor(double y, String collision) {
      final sample = (tubeEvidence['points'] as List)
          .cast<Map>()
          .singleWhere((row) => (row['attackSvg'] as List)[1] == y);
      final level = (sample['levels'] as List).cast<Map>().singleWhere((row) =>
          row['standingClear'] == true &&
          (row['sourceCollisions'] as List).contains(collision));
      return (level['floorMeters'] as num).toDouble();
    }

    SvgHeightSupport tubeSupport(double y, String collision) {
      final floor = tubeFloor(y, collision);
      final support = model.supportForAbsoluteEyeElevation(
          point(185, y), (floor + 1.75) * 100);
      expect(support, isNotNull, reason: '$collision at Tube y=$y');
      return support!;
    }

    final bEvidence = jsonDecode(
        File('test/fixtures/icebox_b_source_levels.json')
            .readAsStringSync()) as Map<String, dynamic>;
    double bFloor(double x, double y, String collision) {
      final sample = (bEvidence['points'] as List).cast<Map>().singleWhere(
          (row) =>
              (row['attackSvg'] as List)[0] == x &&
              (row['attackSvg'] as List)[1] == y);
      final level = (sample['levels'] as List).cast<Map>().singleWhere((row) =>
          row['standingClear'] == true &&
          (row['sourceCollisions'] as List).contains(collision));
      return (level['floorMeters'] as num).toDouble();
    }

    test('Icebox $side bridge ramp and floor below remain distinct', () {
      for (final y in [175.0, 180.0, 185.0]) {
        final origin = point(75, y);
        final lower = bFloor(75, y, 'source-object-4171-part-0');
        final upper = bFloor(75, y, '/Port_BVPawn/BP_BlockingVolume48/Cube#0');
        expect(model.ground!.heightAt(origin), closeTo(lower, 1e-6));
        expect(physicalSupport(75, y, upper).surfaceElevationAt(origin),
            closeTo(upper, .02));
        expect(model.standingSupportAt(origin)?.surfaceElevationAt(origin),
            closeTo(upper, .02));
        final savedLower = model.standingSupportAt(origin,
            savedEyeElevationCm: (lower + 1.75) * 100);
        expect(
            savedLower?.surfaceElevationAt(origin) ??
                model.ground!.heightAt(origin),
            closeTo(lower, .02));
      }
    });

    test('Icebox $side Pipes clear low sections while retaining their column',
        () {
      // BP_BlockingVolume2 measures 6.7693 m. The old render support also
      // extended across [318,209], where the source has no standing domain.
      final support = physicalSupport(323, 209, 6.7693);
      expect(
          model.supportForAbsoluteEyeElevation(
              point(318, 209), (6.7693 + 1.75) * 100),
          isNull);
      expect(
          model.castRay(
              origin: point(323, 209),
              directionRadians: direction(math.pi / 2),
              range: 9,
              supportId: support.id),
          isNull);
      // Aim from the physical pipe at the painted column's center.
      final column = model.castRay(
          origin: point(323, 209),
          directionRadians: direction(math.atan2(213.745 - 209, 318 - 323)),
          range: 9,
          supportId: support.id);
      expect(column?.wallId,
          'p13-stroke-${attack ? 2 : 1}-bottom-local-columns-0');
    });

    test('Icebox $side upper container doorway and Nest north doorway clear',
        () {
      final cases = [
        ('icebox-b-site-upper-floor', 68.0, 198.0, 0.0, 30.0),
        ('icebox-b-site-upper-floor', 84.0, 198.0, 0.0, 15.0),
        ('icebox-a-stacked-b-interior-floor', 344.0, 238.5, -math.pi / 2, 12.0),
      ];
      for (final c in cases) {
        final hit = model.castRay(
            origin: point(c.$2, c.$3),
            directionRadians: direction(c.$4),
            range: c.$5,
            supportId: c.$1 == 'icebox-a-stacked-b-interior-floor'
                ? physicalSupport(c.$2, c.$3, 5.75).id
                : physicalSupport(
                        c.$2,
                        c.$3,
                        bFloor(c.$2, c.$3,
                            '/Port_BVPawn/BP_BlockingVolume538/Cube#0'))
                    .id);
        expect(hit, isNull,
            reason: '${c.$1}: ${hit?.wallId} at ${hit?.distance}');
      }
    });

    test('Icebox $side every offered box level resolves from its saved height',
        () {
      // This little stack has both a grouped support and an individual source
      // record at the same height. It previously fell back to ground in the app.
      final origin = point(254.48755953305334, 65.46700767471);
      final choices = model.supportsAt(origin);
      expect(choices.length, greaterThanOrEqualTo(2));
      for (final choice in choices) {
        final eye =
            choice.surfaceElevationMeters! + model.defaultCameraHeightMeters;
        expect(
            model.supportForAbsoluteEyeElevation(origin, eye * 100), isNotNull,
            reason: choice.id);
      }
    });

    test('Icebox $side raised Nest openings retain their solid bases', () {
      for (final c in [
        ('icebox-a-stacked-b-interior-floor', 338.0, 238.5),
        ('icebox-a-stacked-interior-floor', 333.0, 148.7),
      ]) {
        final lower = model.castRay(
            origin: point(c.$2, c.$3),
            directionRadians: direction(math.pi),
            range: 40);
        final upper = model.castRay(
            origin: point(c.$2, c.$3),
            directionRadians: direction(math.pi),
            range: 40,
            // BP_BlockingVolume73 and BP_BlockingVolume78 supply the
            // 5.75 m player floors above the earlier rendered floor faces.
            supportId: physicalSupport(c.$2, c.$3, 5.75).id);
        expect(lower, isNotNull);
        expect(lower!.distance, lessThan(25));
        expect(upper?.distance ?? 40, greaterThan(30));
      }
    });

    test('Icebox $side Tube window opens while its adjoining wall blocks', () {
      final window = model.castRay(
          origin: point(185, 198), directionRadians: direction(0), range: 30);
      final wall = model.castRay(
          origin: point(185, 188), directionRadians: direction(0), range: 30);
      expect(window?.distance ?? 30, greaterThan(20));
      expect(wall, isNotNull);
      expect(wall!.distance, lessThan(10));
    });

    test('Icebox $side gate allows sight and Belt clears its lower ramp wall',
        () {
      final gate = model.castRay(
          origin: point(351, 252), directionRadians: direction(0), range: 30);
      expect(gate?.distance ?? 30, greaterThan(10));
      final belt = model.castRay(
          origin: point(350, 277),
          directionRadians: direction(math.pi / 2),
          range: 24);
      expect(belt?.distance ?? 24, greaterThan(20));
    });

    test('Icebox $side server cover has a finite height', () {
      expect(
          model.castRay(
              origin: point(296, 224),
              directionRadians: direction(math.pi),
              range: 10),
          isNotNull);
      expect(
          model.castRay(
              origin: point(296, 224),
              directionRadians: direction(math.pi),
              range: 10,
              absoluteEyeElevationMeters: 7),
          isNull);
    });

    test('Icebox $side covered lower crate cannot be selected', () {
      expect(model.supports.any((s) => s.id == 'p9-stroke-0-source-419-top'),
          isFalse);
      expect(model.supports.any((s) => s.id == 'p9-stroke-0-source-420-top'),
          isTrue);
    });

    test('Icebox $side stacked site floors preserve the lower level', () {
      final cases = [
        ('icebox-b-site-upper-floor', 68.1674, 199.763, 5.20333210627238),
        (
          'icebox-b-shipping-d18-top',
          147.58501695875347,
          263.21561458766814,
          4.49997631708781
        ),
        (
          'icebox-a-stacked-interior-floor',
          332.9461471249955,
          147.72538466201343,
          5.75
        ),
        (
          'icebox-a-stacked-b-interior-floor',
          334.56161960550696,
          238.4618886741408,
          5.75
        ),
        (
          'icebox-physical-top-09cfc0386264',
          324.1281133171765,
          199.99608593806965,
          4.5
        ),
        (
          'icebox-a-boost-pipes-top',
          322.9724248033958,
          208.72048745147586,
          6.7693
        ),
      ];
      for (final c in cases) {
        final origin = point(c.$2, c.$3);
        final lower = model.cone(
            origin: origin,
            directionRadians: direction(0),
            range: 30,
            apertureRadians: math.pi / 2);
        final upper = model.cone(
            origin: origin,
            directionRadians: direction(0),
            range: 30,
            apertureRadians: math.pi / 2,
            supportId: physicalSupport(c.$2, c.$3, c.$4).id);
        expect(upper.eyeElevationMeters, closeTo(c.$4 + 1.75, .02),
            reason: c.$1);
        expect(
            lower.eyeElevationMeters, lessThan(upper.eyeElevationMeters! - 1),
            reason:
                'The upper choice must not replace the floor below ${c.$1}.');
      }
    });

    test('Icebox $side zipline and ramp markings are not walls', () {
      final symbols = model.walls.where((w) =>
          w.id.startsWith('p24-stroke-') ||
          w.id == 'p18-stroke-0' ||
          w.id == 'p18-stroke-1');
      expect(symbols, hasLength(16));
      expect(symbols.every((w) => w.bands.isEmpty), isTrue);
      final hit = model.castRay(
          origin: point(354, 215),
          directionRadians: direction(math.pi),
          range: 40);
      expect(hit, isNotNull);
      expect(hit!.distance, greaterThan(12),
          reason: 'The sightline crosses the zipline before reaching cover.');
    });

    test('Icebox $side Tube interior stays upstairs and descends continuously',
        () {
      for (final y in [175.0, 195.0, 215.0]) {
        final origin = point(185, y);
        final expected =
            tubeFloor(y, '/Port_BVPawn/BP_BlockingVolume139/Cube#0');
        final selected = model.automaticSupportAt(origin);
        expect(
            selected?.surfaceElevationAt(origin) ??
                model.ground!.heightAt(origin),
            closeTo(expected, .02));
        expect(
            model.supportsAt(origin).any((s) =>
                s.automaticStandingAllowed &&
                (s.surfaceElevationAt(origin) ?? 0) > expected + .02),
            isFalse,
            reason:
                'The higher Tube shell has no clear player standing floor.');
      }
      final heights = [
        for (final y in [225.0, 235.0, 245.0, 255.0])
          tubeSupport(
                  y,
                  y == 225
                      ? '/Port_BVPawn/BP_BlockingVolume166/Cube#0'
                      : '/Port_BVPawn/BP_BlockingVolume402/Cube#0')
              .surfaceElevationAt(point(185, y))!
      ];
      // The short landing at y=225 must not fall through to the passage below.
      expect(
          heights.first,
          closeTo(
              tubeFloor(225, '/Port_BVPawn/BP_BlockingVolume166/Cube#0'), .02));
      for (var i = 1; i < heights.length; i++) {
        expect(heights[i], lessThan(heights[i - 1]));
      }
      expect(
          model.castRay(
              origin: point(185, 250),
              directionRadians: direction(-math.pi / 2),
              range: 60,
              supportId:
                  tubeSupport(250, '/Port_BVPawn/BP_BlockingVolume402/Cube#0')
                      .id),
          isNull,
          reason: 'Neither ramp marker cuts the connected hallway short.');
    });

    test('Icebox $side Tube upper and lower paths have different sightlines',
        () {
      final origin = point(185, 232);
      final upper = model.castRay(
          origin: origin,
          directionRadians: direction(0),
          range: 25,
          supportId:
              tubeSupport(232, '/Port_BVPawn/BP_BlockingVolume402/Cube#0').id);
      final lower = model.castRay(
          origin: origin,
          directionRadians: direction(0),
          range: 25,
          supportId: 'mid-under-tube');
      expect(upper, isNotNull);
      expect(upper!.distance, lessThan(9));
      expect(lower?.distance ?? 25, greaterThan(12));
      expect(
          model
              .cone(
                  origin: origin,
                  directionRadians: direction(0),
                  range: 25,
                  apertureRadians: math.pi / 2,
                  supportId: 'mid-under-tube')
              .eyeElevationMeters,
          closeTo(2.75, 1e-6));
    });

    test('Icebox $side Tube roof clears its own side walls', () {
      final roof = tubeSupport(232, '/Port_BVPawn/BP_BlockingVolume401/Cube#0');
      expect(
          model
              .automaticSupportAt(point(185, 232))
              ?.surfaceElevationAt(point(185, 232)),
          closeTo(
              tubeFloor(232, '/Port_BVPawn/BP_BlockingVolume401/Cube#0'), .02));
      for (final angle in [0.0, math.pi]) {
        expect(
            model.castRay(
                origin: point(185, 232),
                directionRadians: direction(angle),
                range: 12,
                supportId: roof.id),
            isNull);
      }
      expect(
          model.supports.any((s) =>
              s.id == 'p7-stroke-11-source-4758-top' ||
              s.id == 'p7-stroke-12-source-4757-top'),
          isFalse);
    });
  }
}
