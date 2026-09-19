import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  test('inclined supports use local height for standing, saved levels and rays',
      () {
    final model = SvgHeightVisibility.fromJson({
      'version': 2,
      'coordinateSpace': 'svg',
      'verticalSpace': 'meters-source-elevation',
      'ground': {
        'vertices': [0, 0, 1, 20, 0, 1, 20, 20, 1, 0, 20, 1],
        'triangles': [0, 1, 2, 0, 2, 3],
      },
      'walls': [
        {
          'id': 'cover',
          'rings': [
            [0, 12, 20, 12, 20, 13, 0, 13]
          ],
          'floorElevationMeters': 1,
          'bands': [
            [0, 2.1]
          ],
          'unknownHeight': false,
        }
      ],
      'supports': [
        {
          'id': 'incline',
          'rings': [
            [0, 0, 10, 0, 10, 10, 0, 10]
          ],
          'heightAboveFloorMeters': .5,
          'floorElevationMeters': 1,
          'surfaceElevationMeters': 1.5,
          'surfacePlane': [.1, 0, 1],
          'automaticStandingAllowed': true,
        }
      ],
    });
    const low = Offset(1, 5), high = Offset(9, 5);
    expect(model.automaticSupportAt(low)?.surfaceElevationAt(low),
        closeTo(1.1, 1e-9));
    expect(model.automaticSupportAt(high)?.surfaceElevationAt(high),
        closeTo(1.9, 1e-9));
    expect(model.supportForAbsoluteEyeElevation(high, 365)?.id, 'incline');
    expect(model.supportForAbsoluteEyeElevation(high, 325), isNull);
    expect(
        model
            .castRay(
                origin: low,
                directionRadians: math.pi / 2,
                range: 12,
                supportId: 'incline')
            ?.wallId,
        'cover');
    expect(
        model.castRay(
            origin: high,
            directionRadians: math.pi / 2,
            range: 12,
            supportId: 'incline'),
        isNull);
  });

  test('automatic standing requires gameplay eligibility and respects local XY',
      () {
    Map<String, dynamic> support(String id, double top,
            {bool? allowed, double left = 0}) =>
        {
          'id': id,
          'rings': [
            [left, 0, left + 10, 0, left + 10, 10, left, 10]
          ],
          'heightAboveFloorMeters': top - 1,
          'floorElevationMeters': 1,
          'surfaceElevationMeters': top,
          if (allowed != null) 'automaticStandingAllowed': allowed,
        };
    final model = SvgHeightVisibility.fromJson({
      'version': 2,
      'coordinateSpace': 'svg',
      'verticalSpace': 'meters-source-elevation',
      'walls': [],
      'ground': {
        'vertices': [-20, -20, 1, 50, -20, 1, 50, 50, 1, -20, 50, 1],
        'triangles': [0, 1, 2, 0, 2, 3],
      },
      'supports': [
        support('box', 3, allowed: true),
        support('upper', 5, allowed: true),
        support('roof', 20, allowed: false),
        support('unreviewed', 30),
        support('same-assembly-elsewhere', 8, allowed: true, left: 20),
        support('isolated-roof', 22, allowed: true, left: 40),
      ],
    });
    const point = Offset(5, 5);
    expect(model.automaticSupportAt(point)?.id, 'upper');
    expect(model.automaticSupportAt(const Offset(25, 5))?.id,
        'same-assembly-elsewhere');
    expect(model.automaticSupportAt(const Offset(45, 5))?.id, 'isolated-roof');
    expect(model.standingSupportAt(point, savedEyeElevationCm: 475)?.id, 'box');
    expect(model.standingSupportAt(point, savedEyeElevationCm: 275), isNull);
    expect(
        model.standingSupportAt(point, savedEyeElevationCm: 999)?.id, 'upper');
    expect(model.automaticSupportAt(const Offset(40, 40)), isNull);
  });

  for (final side in ['attack', 'defense']) {
    test('Fracture $side overlapping ground retains the physical upper choice',
        () {
      final review = Platform.environment['ICARUS_HEIGHT_REVIEW'];
      final path = review == null
          ? 'assets/maps/fracture_svg_height_$side.json.gz'
          : '$review/fracture/candidate-$side.json.gz';
      final model = SvgHeightVisibility.fromJson(
          jsonDecode(utf8.decode(gzip.decode(File(path).readAsBytesSync()))));
      final origin = side == 'attack'
          ? const Offset(98.57087287641465, 265.57249412649264)
          : const Offset(361.1671271235854, 207.42750587350736);
      // SuperGrid_Box1027 is above the first ground triangle at this XY.
      final platform = model.supportForAbsoluteEyeElevation(origin, 725.1727);
      expect(platform?.id, 'fracture-physical-top-c1608571986a');
      expect(platform?.surfaceElevationAt(origin), closeTo(5.501727, 1e-6));
      expect(model.groundEyeElevationAt(origin), closeTo(2.7817271, 1e-6));
      expect(model.standingSupportAt(origin, savedEyeElevationCm: 278.17271),
          isNull);
    });
    final reviewDirectory = Platform.environment['ICARUS_HEIGHT_REVIEW'];
    final assetPath = reviewDirectory == null
        ? 'assets/maps/icebox_svg_height_$side.json.gz'
        : '$reviewDirectory/icebox/candidate-$side.json.gz';
    final model = SvgHeightVisibility.fromJson(jsonDecode(
        utf8.decode(gzip.decode(File(assetPath).readAsBytesSync()))));
    Offset point(double x, double y) =>
        side == 'attack' ? Offset(x, y) : Offset(387.459 - x, 473 - y);
    double angle(double a) => a + (side == 'attack' ? 0 : math.pi);
    test(
        'Icebox $side measured ground preserves the floor below the raised ramp',
        () {
      final origin = point(192.34895359539001, 238.50310458167223);
      final support = model.automaticSupportAt(origin);
      expect(support?.id, 'icebox-physical-top-294aba9736d1');
      expect(support?.surfaceElevationAt(origin), closeTo(1.0000001, 1e-6));
      expect(
          model
              .cone(
                  origin: origin,
                  directionRadians: angle(math.pi * .75),
                  range: 65,
                  apertureRadians: math.pi * .75,
                  supportId: support?.id)
              .polygon
              .length,
          greaterThan(3));
      // Floor_4_MidADU and BP_BlockingVolume194 both supply the 1 m floor.
      // The rebuilt ground replaces the old 1.6057 m reference interpolation.
      expect(model.groundEyeElevationAt(origin), closeTo(2.75, 1e-6));
      expect(model.standingSupportAt(origin, savedEyeElevationCm: 275), isNull);
      expect(model.isGroundEyeElevation(origin, 335.571353153), isFalse);
      expect(
          model
              .standingSupportAt(origin, savedEyeElevationCm: 335.571353153)
              ?.id,
          support?.id);
    });
    test(
        'Icebox $side saved gameplay positions select the local playable floor',
        () {
      for (final row in [
        (
          56.26542080938816,
          193.32249161601067,
          // The physical player collider is 18.9 mm above the rendered mesh.
          'icebox-physical-top-9fae3f2e5b30',
          6.9721912
        ),
        // The physical floor is 4.4 mm above the older rendered floor mesh.
        (
          164.51210908591747,
          156.18439988791943,
          'icebox-measured-volume-165-0',
          6.4544126
        ),
        (
          142.64362981915474,
          110.08077466487885,
          'icebox-defender-mid-upper-floor',
          6.25
        ),
        (
          319.53830847144127,
          204.40548986196518,
          // BP_BlockingVolume134's player collider is 4.6 mm above the
          // reviewed rendered pipe faces. Source collider top 5.502050468 m.
          'icebox-measured-volume-695-0',
          7.252050467906776
        ),
      ]) {
        final origin = point(row.$1, row.$2);
        final support = model.automaticSupportAt(origin);
        expect(support?.id, row.$3);
        final cone = model.cone(
            origin: origin,
            directionRadians: 0,
            range: 30,
            apertureRadians: math.pi / 2,
            supportId: support?.id);
        expect(cone.eyeElevationMeters, closeTo(row.$4, .002));
        expect(cone.polygon.length, greaterThan(3));
        if (row.$3 == 'icebox-measured-volume-695-0') {
          expect(support?.label, 'A Site lower pipe step');
        }
        expect(
            model.standingSupportAt(origin,
                savedEyeElevationCm: model.groundEyeElevationAt(origin)! * 100),
            isNull);
      }
    });
    test('Icebox $side upper windows clear while their lower bases block', () {
      for (final row in [
        (
          56.26542080938816,
          193.32249161601067,
          3.0409240014319643,
          6.95333210627238,
          12.0
        ),
        (
          164.51210908591747,
          156.18439988791943,
          1.646920130015424,
          6.450012924975109,
          18.0
        ),
      ]) {
        final origin = point(row.$1, row.$2);
        expect(
            model.castRay(
                origin: origin,
                directionRadians: angle(row.$3),
                range: row.$5,
                absoluteEyeElevationMeters: row.$4),
            isNull);
        expect(
            model.castRay(
                origin: origin,
                directionRadians: angle(row.$3),
                range: row.$5,
                absoluteEyeElevationMeters: 2.75),
            isNotNull);
      }
    });
    test(
        'Icebox $side upper connector sees through the room doorway, lower level does not',
        () {
      final origin = point(142.64362981915474, 110.08077466487885);
      final target = point(145.5, 149);
      final delta = target - origin;
      final direction = math.atan2(delta.dy, delta.dx);
      expect(
          model.castRay(
              origin: origin,
              directionRadians: direction,
              range: delta.distance,
              supportId: model.automaticSupportAt(origin)?.id),
          isNull);
      expect(
          model
              .castRay(
                  origin: origin,
                  directionRadians: direction,
                  range: delta.distance)
              ?.distance,
          lessThan(26));
      // Looking left of the door still meets its actual structural jamb.
      expect(
          model
              .castRay(
                  origin: origin,
                  directionRadians: angle(1.646920130015424),
                  range: 60,
                  supportId: model.automaticSupportAt(origin)?.id)
              ?.distance,
          closeTo(24.829130940482425, .002));
      // The northern tower remains tall despite the finite connector railing.
      expect(
          model.castRay(
              origin: origin,
              directionRadians: angle(-math.pi / 2),
              range: 30,
              supportId: model.automaticSupportAt(origin)?.id),
          isNotNull);
    });
    test(
        'Icebox $side Top Screens selects its playable top and preserves ground',
        () {
      // Saved review 1788883963581-57243566, cone 4. Navigation and
      // BP_BlockingVolume167 establish a 7 m floor, despite a separate nav island.
      final origin = point(295.4071895778179, 165.47969688475132);
      final direction = angle(-0.16361666325461216);
      final support = model.automaticSupportAt(origin);
      expect(support, isNotNull);
      expect(support!.surfaceElevationAt(origin), closeTo(7, .00001));
      final cone = model.cone(
          origin: origin,
          directionRadians: direction,
          range: 56.04072210088962,
          apertureRadians: math.pi / 2,
          supportId: support.id);
      expect(cone.eyeElevationMeters, closeTo(8.75, .00001));
      expect(
          model.castRay(
              origin: origin,
              directionRadians: direction,
              range: 40,
              supportId: support.id),
          isNull);
      expect(
          model
              .castRay(
                  origin: origin,
                  directionRadians: direction,
                  range: 40,
                  absoluteEyeElevationMeters: 3.256722797562449)!
              .distance,
          closeTo(3.416438226487196, .002));
      expect(
          model.standingSupportAt(origin,
              savedEyeElevationCm: 325.6722797562449),
          isNull);
      expect(model.automaticSupportAt(point(302, 165)), isNull);
    });
    test('Icebox $side boost step sees over its own box', () {
      // Pipes on A site: the step is a box drawn as an outline stroke. On the
      // ground beside it the ray stops at the box; on the box it clears the
      // box and reaches the site.
      final origin = point(319.53830847144127, 204.40548986196518);
      final direction = angle(-1.4610461947857607);
      final boosted = model.castRay(
          origin: origin,
          directionRadians: direction,
          range: 60,
          supportId: model.automaticSupportAt(origin)?.id);
      final grounded =
          model.castRay(origin: origin, directionRadians: direction, range: 60);
      expect(grounded?.distance, lessThan(2.5));
      expect(boosted == null || boosted.distance > 20, isTrue,
          reason: 'stopped at ${boosted?.wallId} ${boosted?.distance}');
    });
  }
}
