import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_cone_cache.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  SvgHeightVisibility model() => SvgHeightVisibility.fromJson({
        'version': 1,
        'coordinateSpace': 'svg',
        'verticalSpace': 'meters-above-local-floor',
        'walls': [
          {
            'id': 'cover',
            'rings': [
              [10, -10, 11, -10, 11, 10, 10, 10]
            ],
            'fillRule': 'evenodd',
            'unknownHeight': false,
            'bands': [
              [0, 2]
            ]
          }
        ],
        'supports': [
          {
            'id': 'box',
            'rings': [
              [-1, -1, 1, -1, 1, 1, -1, 1]
            ],
            'fillRule': 'evenodd',
            'heightAboveFloorMeters': 1.0
          }
        ]
      });

  test('one moving observer leaves all other cones untouched', () {
    final cache = SvgHeightConeCache(model());
    SvgCachedCone query(int id, {double x = 0}) => cache.cone(
        observerId: id,
        origin: Offset(x, 0),
        directionRadians: 0,
        range: 30,
        apertureRadians: 1);
    final initial = [for (var i = 0; i < 10; i++) query(i)];
    expect(initial.every((r) => !r.reused), isTrue);
    for (var i = 0; i < 10; i++) {
      final next = query(i, x: i == 3 ? 1 : 0);
      expect(next.reused, i != 3);
      if (i != 3) expect(identical(next.cone, initial[i].cone), isTrue);
    }
    cache.retainObservers([3, 4]);
    expect(cache.observerCount, 2);
    expect(query(3, x: 1).reused, isTrue);
    expect(query(0).reused, isFalse);
    cache.clear();
    expect(cache.observerCount, 0);
  });

  test('every visibility input invalidates the cached cone', () {
    final cache = SvgHeightConeCache(model());
    SvgCachedCone query(
            {Offset origin = Offset.zero,
            double direction = 0,
            double range = 30,
            double aperture = 1,
            double? camera,
            double support = 0,
            String? supportId,
            int arcSteps = 96}) =>
        cache.cone(
            observerId: 'agent',
            origin: origin,
            directionRadians: direction,
            range: range,
            apertureRadians: aperture,
            cameraHeightMeters: camera,
            supportHeightAboveFloorMeters: support,
            supportId: supportId,
            arcSteps: arcSteps);
    final changes = <SvgCachedCone Function()>[
      () => query(origin: const Offset(.1, 0)),
      () => query(direction: .1),
      () => query(range: 31),
      () => query(aperture: 1.1),
      () => query(camera: 2.1),
      () => query(support: 1),
      () => query(supportId: 'box'),
      () => query(arcSteps: 100),
    ];
    for (final change in changes) {
      query();
      expect(query().reused, isTrue);
      expect(change().reused, isFalse);
      expect(change().reused, isTrue);
    }
    expect(query(supportId: 'box').cone.eyeHeightAboveFloorMeters, 2.75);
    expect(SvgHeightConeCache(model()).observerCount, 0);
  });
}
