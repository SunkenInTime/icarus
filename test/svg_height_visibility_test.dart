import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

List<double> rectangle(double x0, double y0, double x1, double y1) =>
    [x0, y0, x1, y0, x1, y1, x0, y1];

Map<String, dynamic> wall(String id, List<List<double>> rings,
        {List<List<num?>> bands = const [
          [0, null]
        ],
        bool unknown = false,
        String fillRule = 'nonzero'}) =>
    {
      'id': id,
      'rings': rings,
      'bands': bands,
      'unknownHeight': unknown,
      'fillRule': fillRule
    };

Map<String, dynamic> data(List<Map<String, dynamic>> walls,
        {List<Map<String, dynamic>> supports = const [],
        List<Map<String, dynamic>> receiver = const [],
        double cellSize = 4}) =>
    {
      'version': 1,
      'coordinateSpace': 'svg',
      'verticalSpace': 'meters-above-local-floor',
      'walls': walls,
      'supports': supports,
      'receiver': receiver,
      'cellSizeSvg': cellSize
    };

SvgVisibilityHit? east(SvgHeightVisibility model,
        {Offset origin = Offset.zero,
        double camera = 1.75,
        String? supportId,
        double range = 100}) =>
    model.castRay(
        origin: origin,
        directionRadians: 0,
        range: range,
        cameraHeightMeters: camera,
        supportId: supportId);

void main() {
  test('a ray aimed at a painted corner cannot slip between both endpoints',
      () {
    const origin = Offset(124.9415684595047, 11.111504460225415);
    const corner = Offset(133.863451727991, 16.93786025368884);
    final model = SvgHeightVisibility.fromJson(data([
      wall('corner',
          [rectangle(corner.dx - 5, corner.dy, corner.dx, corner.dy + 5)])
    ]));
    final delta = corner - origin;
    final hit = model.castRay(
        origin: origin,
        directionRadians: math.atan2(delta.dy, delta.dx),
        range: 70);
    expect(hit, isNotNull);
    expect((hit!.point - corner).distance, lessThan(1e-11));
    expect(
        model.castRay(
            origin: origin,
            directionRadians: math.atan2(delta.dy, delta.dx) - 1e-8,
            range: 70),
        isNull,
        reason: 'A nearby ray that misses the corner remains clear.');
  });
  test('runtime removes only duplicates and forward axis-aligned intermediates',
      () {
    final points = <double>[
      1,
      0,
      2,
      0,
      2,
      0,
      2,
      1,
      2,
      2,
      1,
      2,
      0,
      2,
      0,
      1,
      0,
      0,
      1,
      0,
    ];
    final model = SvgHeightVisibility.fromJson(data([
      wall('rectangle', [points])
    ]));
    expect(model.runtimeEdgeCount, 4);
    expect(model.walls.single.rings.single, [
      for (var i = 0; i < points.length; i += 2)
        Offset(points[i], points[i + 1])
    ]);
    final reverse = SvgHeightVisibility.fromJson(data([
      wall('turn-back', [
        [0, 0, 2, 0, 1, 0, 1, 2, 0, 2]
      ])
    ]));
    expect(reverse.runtimeEdgeCount, 5);
    final near = SvgHeightVisibility.fromJson(data([
      wall('tiny-bend', [
        [0, 0, 1, 1e-12, 2, 0, 2, 2, 0, 2]
      ])
    ]));
    expect(near.runtimeEdgeCount, 5);
    final diagonal = SvgHeightVisibility.fromJson(data([
      wall('diagonal', [
        [0, 0, 1, 1, 2, 2, 0, 2]
      ])
    ]));
    expect(diagonal.runtimeEdgeCount, 4);
  });

  test('rays stop on observer-facing ink for different actual stroke widths',
      () {
    final thin = SvgHeightVisibility.fromJson(data([
      wall('half-width', [rectangle(9.75, -5, 10.25, 5)])
    ]));
    final thick = SvgHeightVisibility.fromJson(data([
      wall('two-width', [rectangle(9, -5, 11, 5)])
    ]));
    expect(east(thin)!.distance, 9.75);
    expect(east(thick)!.distance, 9);
    expect(east(thick, origin: const Offset(20, 0)), isNull);
    final reverse = thick.castRay(
        origin: const Offset(20, 0), directionRadians: math.pi, range: 100);
    expect(reverse!.point.dx, closeTo(11, 1e-12));
  });

  test('authored miter tip is not rounded into a capsule', () {
    final model = SvgHeightVisibility.fromJson(data([
      wall('miter', [
        [10, 0, 12, 2, 12, 8, 10, 10, 8, 8, 8, 2]
      ])
    ]));
    final hit = model.castRay(
        origin: const Offset(10, -5), directionRadians: math.pi / 2, range: 20);
    expect(hit!.point.dx, closeTo(10, 1e-12));
    expect(hit.point.dy, closeTo(0, 1e-12));
  });

  test('nonzero and evenodd holes remain open until their painted inner edge',
      () {
    for (final rule in ['nonzero', 'evenodd']) {
      final model = SvgHeightVisibility.fromJson(data([
        wall(
            'outline',
            [
              rectangle(10, 10, 20, 20),
              [12, 12, 12, 18, 18, 18, 18, 12]
            ],
            fillRule: rule)
      ]));
      expect(east(model, origin: const Offset(15, 15))!.distance, 3);
      expect(east(model, origin: const Offset(11, 15))!.distance, 0);
    }
  });

  test('vertical opening and finite low cover preserve clear standing sight',
      () {
    final opening = SvgHeightVisibility.fromJson(data([
      wall('window', [
        rectangle(10, -5, 11, 5)
      ], bands: [
        [0, 1],
        [2.5, null]
      ])
    ]));
    expect(east(opening), isNull);
    expect(east(opening, camera: .8)!.distance, 10);
    expect(east(opening, camera: 2.8)!.distance, 10);
    final low = SvgHeightVisibility.fromJson(data([
      wall('low', [
        rectangle(10, -5, 11, 5)
      ], bands: [
        [0, 1]
      ])
    ]));
    expect(east(low), isNull);
  });

  test('selected box top clears its own sides but retains the next tall wall',
      () {
    final model = SvgHeightVisibility.fromJson(data([
      wall('box', [
        rectangle(4, 2, 8, 8),
        [4.5, 2.5, 4.5, 7.5, 7.5, 7.5, 7.5, 2.5]
      ], bands: [
        [0, 2]
      ]),
      wall('room', [
        rectangle(15, 0, 16, 10)
      ], bands: [
        [0, 10]
      ]),
    ], supports: [
      {
        'id': 'box-top',
        'rings': [rectangle(4, 2, 8, 8)],
        'heightAboveFloorMeters': 2
      },
      {
        'id': 'upper-floor',
        'rings': [rectangle(4, 2, 8, 8)],
        'heightAboveFloorMeters': 6
      },
    ]));
    const origin = Offset(6, 5);
    expect(
        model.supportsAt(origin).map((s) => s.id), ['box-top', 'upper-floor']);
    expect(east(model, origin: origin)!.wallId, 'box');
    expect(east(model, origin: origin, supportId: 'box-top')!.wallId, 'room');
    expect(model.selectedSupportHeight(origin, 'box-top'), 2);
    expect(() => east(model, supportId: 'box-top'), throwsArgumentError);
    expect(() => east(model, origin: origin, supportId: 'missing'),
        throwsArgumentError);
  });

  test('absolute eye elevation selects one explicit contained support', () {
    final model = SvgHeightVisibility.fromJson(data([], supports: [
      {
        'id': 'lower',
        'label': 'Lower crate',
        'rings': [rectangle(0, 0, 10, 10)],
        'heightAboveFloorMeters': 2,
        'floorElevationMeters': 3,
        'surfaceElevationMeters': 5,
      },
      {
        'id': 'upper',
        'rings': [rectangle(0, 0, 10, 10)],
        'heightAboveFloorMeters': 4,
        'floorElevationMeters': 3,
        'surfaceElevationMeters': 7,
      },
    ], receiver: [
      {
        'rings': [rectangle(0, 0, 20, 20)],
        'fillRule': 'evenodd',
      }
    ]));
    const point = Offset(5, 5);
    expect(model.receiverContains(point), isTrue);
    expect(model.receiverContains(const Offset(30, 30)), isFalse);
    expect(model.supportForAbsoluteEyeElevation(point, 675)!.id, 'lower');
    expect(model.supportForAbsoluteEyeElevation(point, 875)!.id, 'upper');
    expect(model.supportForAbsoluteEyeElevation(point, 999), isNull);
    expect(model.supportForAbsoluteEyeElevation(const Offset(15, 15), 675),
        isNull);
    expect(model.supports.first.label, 'Lower crate');
  });

  test('overlapping records at one elevation preserve the selected level', () {
    final support = {
      'rings': [rectangle(0, 0, 10, 10)],
      'heightAboveFloorMeters': 2,
      'floorElevationMeters': 3,
      'surfaceElevationMeters': 5,
    };
    final model = SvgHeightVisibility.fromJson(data([], supports: [
      {'id': 'one', ...support},
      {'id': 'two', ...support},
    ]));
    expect(
        model
            .supportForAbsoluteEyeElevation(const Offset(5, 5), 675)
            ?.surfaceElevationMeters,
        5);
    final distinct = SvgHeightVisibility.fromJson(data([], supports: [
      {'id': 'lower', ...support},
      {
        'id': 'upper',
        ...support,
        'surfaceElevationMeters': 7,
        'heightAboveFloorMeters': 4
      },
    ]));
    expect(
        distinct.supportForAbsoluteEyeElevation(const Offset(5, 5), 775,
            toleranceCm: 150),
        isNull);
  });

  test('connected ramp samples cannot create runtime XY walls', () {
    final input = data([
      wall('real-wall', [rectangle(30, -4, 31, 4)])
    ]);
    input['groundSamples'] = [
      [0, 0, 8],
      [10, 0, 4],
      [20, 0, 0]
    ];
    final model = SvgHeightVisibility.fromJson(input);
    expect(east(model)!.distance, 30);
    expect(east(model, range: 25), isNull);
    expect(model.walls.length, 1);
  });

  test('long wall meets the range circle without an early diagonal cutoff', () {
    final model = SvgHeightVisibility.fromJson(data([
      wall('long-wall', [rectangle(-100, 1, 100, 2)])
    ]));
    final cone = model.cone(
        origin: Offset.zero,
        directionRadians: math.pi,
        range: 90,
        apertureRadians: math.pi / 2);
    final contact = Offset(-math.sqrt(90 * 90 - 1), 1);
    expect(cone.polygon.map((p) => (p - contact).distance).reduce(math.min),
        lessThan(1e-7));
  });

  test('overlapping SVG strokes retain their exact visibility crossing', () {
    final model = SvgHeightVisibility.fromJson(data([
      wall('horizontal', [rectangle(-100, 1, 100, 2)]),
      wall('vertical', [rectangle(-6, -10, -5, 10)]),
    ]));
    final cone = model.cone(
        origin: Offset.zero,
        directionRadians: math.pi,
        range: 90,
        apertureRadians: math.pi / 2);
    expect(
        cone.polygon
            .map((p) => (p - const Offset(-5, 1)).distance)
            .reduce(math.min),
        lessThan(1e-7));
  });

  test('unknown wall height is explicit and stays opaque at a raised eye', () {
    final model = SvgHeightVisibility.fromJson(data([
      wall('unknown', [rectangle(10, -2, 11, 2)], bands: [], unknown: true)
    ]));
    final hit = east(model, camera: 20)!;
    expect(hit.unknownHeight, isTrue);
    expect(hit.distance, 10);
  });

  test('corner rays resolve a narrow blocker between the regular cone rays',
      () {
    final model = SvgHeightVisibility.fromJson(data([
      wall('narrow', [rectangle(10, .1, 10.1, .15)])
    ]));
    final cone = model.cone(
        origin: Offset.zero,
        directionRadians: 0,
        range: 30,
        apertureRadians: .8,
        arcSteps: 2);
    expect(cone.stats.rayCount, greaterThan(3));
    expect(
        cone.polygon
            .any((p) => (p.dx - 10).abs() < 1e-9 && p.dy >= .1 && p.dy <= .15),
        isTrue);
    expect(cone.eyeHeightAboveFloorMeters, 1.75);
  });

  test('spatial tree agrees with analytic rectangle intersections', () {
    final random = math.Random(74);
    final boxes = List.generate(80, (_) {
      final x = random.nextDouble() * 100 - 50;
      final y = random.nextDouble() * 100 - 50;
      return Rect.fromLTWH(
          x, y, .2 + random.nextDouble() * 4, .2 + random.nextDouble() * 4);
    });
    final model = SvgHeightVisibility.fromJson(data([
      for (var i = 0; i < boxes.length; i++)
        wall('$i', [
          rectangle(
              boxes[i].left, boxes[i].top, boxes[i].right, boxes[i].bottom)
        ])
    ], cellSize: 3));
    for (var sample = 0; sample < 300; sample++) {
      final origin = Offset(
          random.nextDouble() * 120 - 60, random.nextDouble() * 120 - 60);
      final angle = random.nextDouble() * math.pi * 2;
      final direction = Offset(math.cos(angle), math.sin(angle));
      double? expected;
      for (final box in boxes) {
        var lo = 0.0, hi = 150.0;
        for (final axis in [
          (origin.dx, direction.dx, box.left, box.right),
          (origin.dy, direction.dy, box.top, box.bottom)
        ]) {
          final a = (axis.$3 - axis.$1) / axis.$2;
          final b = (axis.$4 - axis.$1) / axis.$2;
          lo = math.max(lo, math.min(a, b));
          hi = math.min(hi, math.max(a, b));
        }
        if (lo <= hi) expected = math.min(expected ?? 150, lo);
      }
      final hit =
          model.castRay(origin: origin, directionRadians: angle, range: 150);
      if (expected == null) {
        expect(hit, isNull, reason: 'sample $sample');
      } else {
        expect(hit!.distance, closeTo(expected, 1e-9),
            reason: 'sample $sample');
      }
    }
  });

  test(
      'reports measured query work without a hardware-dependent pass threshold',
      () {
    final model = SvgHeightVisibility.fromJson(data([
      for (var i = 0; i < 120; i++)
        wall('$i', [
          rectangle(
              (i % 12) * 8, (i ~/ 12) * 8, (i % 12) * 8 + 1, (i ~/ 12) * 8 + 4)
        ])
    ]));
    SvgVisibilityCone? result;
    for (var i = 0; i < 15; i++) {
      result = model.cone(
          origin: const Offset(3, 3),
          directionRadians: .6,
          range: 100,
          apertureRadians: 1.8);
    }
    expect(result!.stats.edgeTests, greaterThan(0));
    expect(result.stats.rayCount, greaterThan(96));
    // This is a synthetic Flutter-test run, not a production frame-rate claim.
    // ignore: avoid_print
    print('SVG prototype: ${result.stats.elapsedMicroseconds}us, '
        '${result.stats.rayCount} rays, ${result.stats.edgeTests} edge tests');
  });

  test('rejects missing confidence, invalid units and reversed intervals', () {
    final missing = wall('a', [rectangle(1, 1, 2, 2)])..remove('unknownHeight');
    expect(() => SvgHeightVisibility.fromJson(data([missing])),
        throwsFormatException);
    expect(
        () => SvgHeightVisibility.fromJson(data([
              wall('a', [
                rectangle(1, 1, 2, 2)
              ], bands: [
                [2, 1]
              ])
            ])),
        throwsFormatException);
    final units = data([])..['verticalSpace'] = 'unknown';
    expect(() => SvgHeightVisibility.fromJson(units), throwsFormatException);
  });

  test('accepts a valid tiny translated ring and rejects a collinear ring', () {
    final tiny = wall('tiny', [
      [
        323.77748564048954,
        215.88724230239188,
        323.77748564048954,
        215.88723830163502,
        323.777484597012,
        215.8870664999608,
        323.77748564048954,
        215.88724230239188,
      ]
    ]);
    expect(SvgHeightVisibility.fromJson(data([tiny])).walls, hasLength(1));

    final collinear = wall('line', [
      [300, 200, 301, 201, 302, 202]
    ]);
    expect(() => SvgHeightVisibility.fromJson(data([collinear])),
        throwsFormatException);
  });
}
