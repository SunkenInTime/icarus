import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_cone_cache.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

Map<String, dynamic> fixture() => {
  'version': 2,
  'coordinateSpace': 'svg',
  'verticalSpace': 'meters-source-elevation',
  'ground': {
    // Continuous ramp from elevation zero to four. It creates no walls.
    'vertices': [0,0,0, 20,0,4, 20,20,4, 0,20,0],
    'triangles': [0,1,2, 0,2,3],
  },
  'walls': [{
    'id': 'ledge', 'rings': [[10,0,11,0,11,20,10,20]],
    'floorElevationMeters': 0, 'bands': [[0,3]], 'unknownHeight': false,
  }],
  'supports': [{
    'id': 'upper', 'label': 'Upper platform',
    'rings': [[1,1,19,1,19,19,1,19]],
    'heightAboveFloorMeters': 5, 'floorElevationMeters': 0,
    'surfaceElevationMeters': 5,
  }],
};

void main() {
  test('ground raises the observer without generating terrain blockers', () {
    final model = SvgHeightVisibility.fromJson(fixture());
    expect(model.ground!.heightAt(const Offset(5,5)), closeTo(1,1e-9));
    final low = model.castRay(origin: const Offset(2,5),
        directionRadians: 0, range: 17);
    expect(low!.point, const Offset(10,5));
    // Same ledge seen from above is clear, including the downhill floor.
    final high = model.castRay(origin: const Offset(18,5),
        directionRadians: 3.141592653589793, range: 17);
    expect(high, isNull);
    expect(model.runtimeEdgeCount, 4);
  });

  test('an explicit upper support is distinct from primary ground', () {
    final model = SvgHeightVisibility.fromJson(fixture());
    final ground = model.cone(origin: const Offset(2,5), directionRadians: 0,
        range: 15, apertureRadians: 1);
    final upper = model.cone(origin: const Offset(2,5), directionRadians: 0,
        range: 15, apertureRadians: 1, supportId: 'upper');
    expect(ground.eyeElevationMeters, closeTo(2.15,1e-9));
    expect(upper.eyeElevationMeters, 6.75);
    expect(model.supportForAbsoluteEyeElevation(const Offset(2,5), 675)?.id,
        'upper');
    expect(model.supportForAbsoluteEyeElevation(const Offset(2,5), 500), isNull);
  });

  test('absolute eye changes invalidate cached results', () {
    final cache = SvgHeightConeCache(SvgHeightVisibility.fromJson(fixture()));
    SvgCachedCone query(double eye) => cache.cone(observerId: 'one',
        origin: const Offset(2,5), directionRadians: 0, range: 15,
        apertureRadians: 1, absoluteEyeElevationMeters: eye);
    expect(query(2).reused, false);
    expect(query(2).reused, true);
    expect(query(4).reused, false);
    expect(query(4).reused, true);
  });

  test('source schema requires ground and explicit wall datums', () {
    final missingGround = fixture()..remove('ground');
    expect(() => SvgHeightVisibility.fromJson(missingGround), throwsFormatException);
    final missingDatum = fixture();
    (missingDatum['walls'] as List).first.remove('floorElevationMeters');
    expect(() => SvgHeightVisibility.fromJson(missingDatum), throwsFormatException);
  });
}
