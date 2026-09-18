import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

/// A view cone shows the ground a player can be seen standing on. Every case
/// here reads the same way: an eye, a wall it looks over, and the first ground
/// behind that wall where a standing head rises above the wall's top.
List<double> rectangle(double x0, double y0, double x1, double y1) =>
    [x0, y0, x1, y0, x1, y1, x0, y1];

Map<String, dynamic> wall(String id, List<double> ring,
        {double floor = 0, required double top}) =>
    {
      'id': id,
      'rings': [ring],
      'floorElevationMeters': floor,
      'bands': [
        [0, top - floor]
      ],
      'unknownHeight': false,
    };

Map<String, dynamic> support(String id, List<double> ring, double surface) => {
      'id': id,
      'rings': [ring],
      'heightAboveFloorMeters': surface,
      'floorElevationMeters': 0,
      'surfaceElevationMeters': surface,
    };

/// Flat ground from the observer out past every wall these tests place.
const flatGround = {
  'vertices': [-100, -100, 0, 700, -100, 0, 700, 100, 0, -100, 100, 0],
  'triangles': [0, 1, 2, 0, 2, 3],
};

/// Ground at three metres west of x = 0 and at zero east of it: the shape a
/// drop-off has once its edge is painted as a wall.
const steppedGround = {
  'vertices': [
    -100, -100, 3, 0, -100, 3, 0, 100, 3, -100, 100, 3, //
    1, -100, 0, 700, -100, 0, 700, 100, 0, 1, 100, 0
  ],
  'triangles': [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7],
};

SvgHeightVisibility model(List<Map<String, dynamic>> walls,
        {List<Map<String, dynamic>> supports = const [],
        Map<String, dynamic> ground = flatGround}) =>
    SvgHeightVisibility.fromJson({
      'version': 2,
      'coordinateSpace': 'svg',
      'verticalSpace': 'meters-source-elevation',
      'ground': ground,
      'walls': walls,
      'supports': supports,
    });

List<(double, double)> east(SvgHeightVisibility model,
        {Offset origin = Offset.zero, String? supportId, double range = 100}) =>
    model.visibleIntervalsAlong(
        origin: origin,
        direction: const Offset(1, 0),
        range: range,
        supportId: supportId);

/// Whether a player standing this far east would be seen standing there.
bool seenAt(SvgHeightVisibility model, double distance,
        {Offset origin = Offset.zero, String? supportId}) =>
    east(model, origin: origin, supportId: supportId, range: distance)
        .any((span) => distance >= span.$1 && distance <= span.$2);

/// What stops the eye, which the wall data is still checked against.
SvgVisibilityHit? eastRay(SvgHeightVisibility model,
        {Offset origin = Offset.zero,
        String? supportId,
        required double range}) =>
    model.castRay(
        origin: origin,
        directionRadians: 0,
        range: range,
        supportId: supportId);

SvgVisibilityCone eastCone(SvgHeightVisibility model,
        {Offset origin = Offset.zero, String? supportId, double range = 500}) =>
    model.cone(
        origin: origin,
        directionRadians: 0,
        range: range,
        apertureRadians: 1,
        supportId: supportId);

void expectIntervals(
    List<(double, double)> actual, List<(double, double)> expected) {
  expect(actual.length, expected.length,
      reason: 'Intervals $actual, expected $expected.');
  for (var i = 0; i < expected.length; i++) {
    expect(actual[i].$1, closeTo(expected[i].$1, 1e-6));
    expect(actual[i].$2, closeTo(expected[i].$2, 1e-6));
  }
}

void main() {
  test('a wall no taller than a player changes nothing from the ground', () {
    final low = model([wall('brick', rectangle(35, -100, 37, 100), top: 1.2)]);
    expect(eastRay(low, range: 110), isNull);
    expect(seenAt(low, 110), isTrue);
    expectIntervals(east(low), [(0, 100)]);
    expect(eastCone(low).visibilityPath, isNull,
        reason: 'A ground pose still paints the horizontal polygon.');
  });

  test('a box observer cannot see the ground behind a wall they look over', () {
    final high = model([wall('tall', rectangle(35, -100, 37, 100), top: 4.4)],
        supports: [support('box', rectangle(-5, -5, 5, 5), 3)]);
    // Eye 4.75, wall top 4.4, head behind it 1.75, near face 35 units away:
    // the line to a head clears 4.4 only at 35 * 3 / .35 = 300 units.
    expect(seenAt(high, 110, supportId: 'box'), isFalse);
    expect(seenAt(high, 400, supportId: 'box'), isTrue);
    expectIntervals(
        east(high, supportId: 'box', range: 500), [(0, 37.5), (300, 500)]);
    expect(eastRay(high, range: 110, supportId: 'box'), isNull,
        reason: 'The eye still has its clear line over the wall. Only the '
            'ground behind the wall is out of view.');
  });

  test('ground far enough behind a lower wall comes back into view', () {
    final medium = model([wall('mid', rectangle(35, -100, 37, 100), top: 2.5)],
        supports: [support('box', rectangle(-5, -5, 5, 5), 3)]);
    // 35 * 3 / 2.25 = 46.67 units: a head at 45 is hidden, one at 110 is not.
    expect(seenAt(medium, 110, supportId: 'box'), isTrue);
    expect(seenAt(medium, 45, supportId: 'box'), isFalse);
    expectIntervals(
        east(medium, supportId: 'box', range: 500), [(0, 37.5), (140 / 3, 500)]);
  });

  test('the visible path drops the strip behind the wall and keeps the rest',
      () {
    final high = model([wall('tall', rectangle(35, -100, 37, 100), top: 4.4)],
        supports: [support('box', rectangle(-5, -5, 5, 5), 3)]);
    final path = eastCone(high, supportId: 'box').visibilityPath;
    expect(path, isNotNull);
    expect(path!.contains(const Offset(20, 0)), isTrue,
        reason: 'Ground in front of the wall stays visible.');
    expect(path.contains(const Offset(100, 0)), isFalse,
        reason: 'A player just behind the wall is hidden by it.');
    expect(path.contains(const Offset(400, 0)), isTrue,
        reason: 'Far ground rises above the wall top again.');
  });

  test('a taller wall behind a low one hides everything between them', () {
    final pair = model([
      wall('low', rectangle(35, -100, 37, 100), top: 2.5),
      wall('blocking', rectangle(45, -100, 47, 100), top: 6),
    ], supports: [
      support('box', rectangle(-5, -5, 5, 5), 3)
    ]);
    // The low wall hides ground out to 46.67; the six metre wall stops the eye
    // at 45. Nothing between the two walls is visible from the box.
    expectIntervals(east(pair, supportId: 'box'), [(0, 37.5)]);
    expect(seenAt(pair, 40, supportId: 'box'), isFalse);
    expect(eastRay(pair, range: 40, supportId: 'box'), isNull,
        reason: 'The low wall never stops the eye.');
    expect(eastRay(pair, range: 60, supportId: 'box')?.wallId, 'blocking');
  });

  test('the edge of the box the observer stands on hides nothing', () {
    final edged = model([wall('box-edge', rectangle(4, -5, 5, 5), top: 3)],
        supports: [support('box', rectangle(-5, -5, 5, 5), 3)]);
    expectIntervals(east(edged, supportId: 'box'), [(0, 100)]);
    expect(eastCone(edged, supportId: 'box').visibilityPath, isNull,
        reason: 'Nothing hides ground, so the horizontal polygon still holds.');
  });

  test('a wall beyond the box still hides the ground right behind it', () {
    final both = model([
      wall('box-edge', rectangle(4, -5, 5, 5), top: 3),
      wall('crate', rectangle(20, -100, 21, 100), top: 2.5),
    ], supports: [
      support('box', rectangle(-5, -5, 5, 5), 3)
    ]);
    // 20 * 3 / 2.25 = 26.67 units, measured from half a unit past the crate.
    expectIntervals(east(both, supportId: 'box'), [(0, 21.5), (80 / 3, 100)]);
    final path = eastCone(both, supportId: 'box', range: 100).visibilityPath;
    expect(path, isNotNull);
    expect(path!.contains(const Offset(10, 0)), isTrue,
        reason: 'Ground between the box and the crate is in view.');
    expect(path.contains(const Offset(24, 0)), isFalse,
        reason: 'The strip right behind the crate is hidden.');
    expect(path.contains(const Offset(50, 0)), isTrue,
        reason: 'Far ground is visible over the crate.');
  });

  test('a drop-off edge below the observer is their own floor, not a wall', () {
    final ledge = model([
      wall('drop', rectangle(0, -100, 1, 100), top: 3),
      wall('crate', rectangle(30, -100, 31, 100), top: 2),
    ], ground: steppedGround);
    const origin = Offset(-20, 0);
    expect(ledge.ground!.heightAt(origin), 3);
    // The drop-off exempts itself; the crate 50 units out hides ground until
    // 50 * 3 / 2.75 = 54.55 units.
    expectIntervals(east(ledge, origin: origin), [(0, 51.5), (600 / 11, 100)]);
    expect(seenAt(ledge, 20, origin: origin), isTrue,
        reason: 'The ground at the foot of the drop is in plain view.');
    expect(seenAt(ledge, 52, origin: origin), isFalse);
  });
}
