import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

Map<String, dynamic> modelData({List<int> standing = const []}) => {
      'version': 3,
      'coordinateSpace': 'svg',
      'verticalSpace': 'meters-source-elevation',
      'walls': [],
      'ground': <String, dynamic>{
        'vertices': [0, 0, 4, 10, 0, 4, 0, 10, 4],
        'triangles': [0, 1, 2],
        'standingTriangles': standing,
      },
      'supports': <Map<String, dynamic>>[
        {
          'id': 'physical-floor',
          'rings': [
            [0, 0, 10, 0, 0, 10]
          ],
          'heightAboveFloorMeters': 2,
          'floorElevationMeters': 0,
          'surfaceElevationMeters': 2,
          'automaticStandingAllowed': true,
        }
      ],
    };

void main() {
  const point = Offset(2, 2);
  test('a saved Tube interior stays below the roof after source rounding', () {
    final data = modelData(standing: [0]);
    (data['ground'] as Map)['vertices'] = [0, 0, 1, 10, 0, 1, 0, 10, 1];
    final floor = (data['supports'] as List).single as Map<String, dynamic>;
    floor['surfaceElevationMeters'] = 3.9763197;
    floor['heightAboveFloorMeters'] = 3.9763197;
    (data['supports'] as List).add({
      ...floor,
      'id': 'roof',
      'surfaceElevationMeters': 7.6854315,
      'heightAboveFloorMeters': 7.6854315
    });
    final model = SvgHeightVisibility.fromJson(data);
    // Before asset: native incline 3.976023398496082 m at attack [185,232].
    // Independent collision-plane measurement: 3.9763197 m at the same point.
    const savedEye = (3.976023398496082 + 1.75) * 100;
    final previousMatching =
        SvgHeightVisibility.fromJson({...data, 'version': 2});
    expect(
        previousMatching
            .standingSupportAt(point, savedEyeElevationCm: savedEye)
            ?.id,
        'roof',
        reason: 'The original matching tolerance loses the saved interior.');
    expect(model.standingSupportAt(point)?.id, 'roof');
    expect(model.standingSupportAt(point, savedEyeElevationCm: savedEye)?.id,
        'physical-floor');
    expect(
        model.supportForAbsoluteEyeElevation(point, savedEye, toleranceCm: .01),
        isNull);
  });

  test(
      'nearby saved levels resolve separately from ground without guessing ties',
      () {
    final data = modelData(standing: [0]);
    (data['ground'] as Map)['vertices'] = [
      0,
      0,
      1.461481,
      10,
      0,
      1.461481,
      0,
      10,
      1.461481
    ];
    final floor = (data['supports'] as List).single as Map<String, dynamic>;
    floor['surfaceElevationMeters'] = 1.465011;
    floor['heightAboveFloorMeters'] = 1.465011;
    (data['supports'] as List).add({
      ...floor,
      'id': 'upper',
      'surfaceElevationMeters': 1.491374,
      'heightAboveFloorMeters': 1.491374
    });
    final model = SvgHeightVisibility.fromJson(data);
    const groundEye = (1.461481 + 1.75) * 100;
    const middleEye = (1.465011 + 1.75) * 100;
    expect(
        model.standingSupportAt(point, savedEyeElevationCm: groundEye), isNull);
    expect(model.isGroundEyeElevation(point, groundEye), isTrue);
    expect(model.standingSupportAt(point, savedEyeElevationCm: middleEye)?.id,
        'physical-floor');
    expect(model.isGroundEyeElevation(point, middleEye), isFalse);
    const between = (groundEye + middleEye) / 2;
    expect(model.supportForAbsoluteEyeElevation(point, between), isNull);
    expect(model.isGroundEyeElevation(point, between), isFalse);
    expect(model.standingSupportAt(point, savedEyeElevationCm: between)?.id,
        'upper');
    expect(model.supportForAbsoluteEyeElevation(point, 900), isNull);
  });

  test('support boundaries admit rounding without expanding wall ink', () {
    final data = modelData();
    data['walls'] = [
      {
        'id': 'wall',
        'rings': [
          [0, 0, 10, 0, 0, 10]
        ],
        'floorElevationMeters': 0,
        'bands': [
          [0, 4]
        ],
        'unknownHeight': false,
      }
    ];
    final model = SvgHeightVisibility.fromJson(data);
    for (final offset in [5e-9, 2e-8]) {
      final roundedBoundary = Offset(5, 5 + offset);
      expect(model.supports.single.contains(roundedBoundary), isTrue);
      expect(model.walls.single.contains(roundedBoundary), isFalse);
    }
    expect(model.supports.single.contains(const Offset(5, 5 + 5e-8)), isFalse);
    expect(model.supports.single.contains(const Offset(5, 5 + 1e-6)), isFalse);
  });

  test('reference interpolation cannot overrule a physical floor', () {
    final model = SvgHeightVisibility.fromJson(modelData());
    expect(model.ground!.heightAt(point), 4);
    expect(model.ground!.standingHeightAt(point), isNull);
    expect(model.standingSupportAt(point)?.id, 'physical-floor');
    expect(model.standingSupportAt(point, savedEyeElevationCm: 575), isNull);
    expect(model.groundEyeElevationAt(point), 5.75,
        reason: 'An explicit saved reference height remains available.');
  });

  test('verified higher ground retains priority over a lower support', () {
    final model = SvgHeightVisibility.fromJson(modelData(standing: [0]));
    expect(model.ground!.standingHeightAt(point), 4);
    expect(model.standingSupportAt(point), isNull);
    expect(model.standingSupportAt(point, savedEyeElevationCm: 375)?.id,
        'physical-floor');
  });

  test('a hidden ground triangle cannot certify the covering reference', () {
    final data = modelData(standing: [1]);
    final ground = data['ground'] as Map<String, dynamic>;
    ground['vertices'] = [
      0,
      0,
      4,
      10,
      0,
      4,
      0,
      10,
      4,
      0,
      0,
      1,
      10,
      0,
      1,
      0,
      10,
      1
    ];
    ground['triangles'] = [0, 1, 2, 3, 4, 5];
    final model = SvgHeightVisibility.fromJson(data);
    expect(model.ground!.standingHeightAt(point), isNull);
    expect(model.standingSupportAt(point)?.id, 'physical-floor');
  });

  test('new data requires valid explicit physical-ground eligibility', () {
    final missing = modelData();
    (missing['ground'] as Map).remove('standingTriangles');
    expect(() => SvgHeightVisibility.fromJson(missing), throwsFormatException);
    for (final ids in [
      [1],
      [0, 0],
      [-1]
    ]) {
      expect(() => SvgHeightVisibility.fromJson(modelData(standing: ids)),
          throwsFormatException);
    }
  });

  test('existing version two data retains its previous selection behavior', () {
    final data = modelData()..['version'] = 2;
    (data['ground'] as Map).remove('standingTriangles');
    final model = SvgHeightVisibility.fromJson(data);
    expect(model.standingSupportAt(point), isNull);
  });
}
