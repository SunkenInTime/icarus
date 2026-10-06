import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

/// A cone's outline is a fan of rays from the eye joined by straight lines.
/// The cone query skips every ray it can prove would land in the middle of a
/// wall another ray already covers. If it ever skips a real corner, the line
/// joining its neighbours cuts across a wall or a gap. So in every direction
/// a single exact ray must end where the outline does: on the wall it meets,
/// or, in open sky, on the chord the outline draws along the range circle.
///
/// Directions come from the outline (between each pair of its points) and,
/// independently of it, from just either side of every wall corner in range
/// and an even sweep, so a wall the query missed entirely is still probed.
SvgHeightVisibility _model(Map<String, dynamic> json, {String? nativeLibrary}) {
  final model = SvgHeightVisibility.fromJson(json);
  if (nativeLibrary != null) {
    expect(model.enableNativeAcceleration(libraryPath: nativeLibrary), isTrue);
  }
  return model;
}

Map<String, dynamic> _asset(String name) => jsonDecode(utf8.decode(
        gzip.decode(File('assets/maps/$name.json.gz').readAsBytesSync())))
    as Map<String, dynamic>;

List<double> _rectangle(double x0, double y0, double x1, double y1) =>
    [x0, y0, x1, y0, x1, y1, x0, y1];

Map<String, dynamic> _walls(List<List<double>> rings) => {
      'version': 1,
      'coordinateSpace': 'svg',
      'verticalSpace': 'meters-above-local-floor',
      'walls': [
        for (var i = 0; i < rings.length; i++)
          {
            'id': 'wall-$i',
            'rings': [rings[i]],
            'bands': [
              [0, null]
            ],
            'unknownHeight': false,
            'fillRule': 'nonzero',
          }
      ],
      'supports': const [],
      'receiver': const [],
      'cellSizeSvg': 4,
    };

double _relative(Offset delta, double direction) {
  final turn = math.atan2(delta.dy, delta.dx) - direction;
  return math.atan2(math.sin(turn), math.cos(turn));
}

/// The places where [model]'s cone outline disagrees with exact rays.
List<String> _wrong(SvgHeightVisibility model, Offset eye, double direction,
    double aperture, double range) {
  final outline = model
      .horizontalCone(
          origin: eye,
          directionRadians: direction,
          range: range,
          apertureRadians: aperture,
          supportId: model.automaticSupportAt(eye)?.id)
      .polygon;
  return _wrongOutline(model, outline, eye, direction, aperture, range);
}

/// The places where [outline] disagrees with exact rays through [model].
List<String> _wrongOutline(SvgHeightVisibility model, List<Offset> outline,
    Offset eye, double direction, double aperture, double range) {
  final support = model.automaticSupportAt(eye)?.id;
  final points = outline.skip(1).toList();
  if (points.length < 2) return ['no outline'];
  final half = aperture / 2;
  // Angles in ray order, from the cone's first edge: on a full circle the
  // first and last points lie on the same line, at -half and half.
  double turn(double angle) => math.atan2(math.sin(angle), math.cos(angle));
  final angles = <double>[
    -half + turn(_relative(points.first - eye, direction) + half)
  ];
  for (final p in points.skip(1)) {
    final previous = angles.last;
    angles.add(previous + turn(_relative(p - eye, direction) - previous));
  }
  final probes = <double>[
    for (var i = 0; i + 1 < angles.length; i++) (angles[i] + angles[i + 1]) / 2,
    for (final wall in model.walls)
      for (final ring in wall.rings)
        for (final corner in ring)
          if ((corner - eye).distance <= range) ...[
            _relative(corner - eye, direction) - 1e-6,
            _relative(corner - eye, direction) + 1e-6,
          ],
    for (var i = 0; i < 200; i++) -half + aperture * (i + 0.5) / 200,
  ];
  final wrong = <String>[];
  for (final angle in probes) {
    if (angle <= -half || angle >= half) continue;
    // The outline point pair the probe falls between, in ray order.
    var after = 0;
    while (after < angles.length && angles[after] < angle) {
      after++;
    }
    if (after == 0 || after == angles.length) continue;
    final gap = angles[after] - angles[after - 1];
    // Beside a silhouette the outline draws a chord between the corner ray
    // and the ray 1e-8 past it, by design.
    if (gap < 1e-7) continue;
    final world = direction + angle;
    final ray = Offset(math.cos(world), math.sin(world));
    final a = points[after - 1] - eye, b = points[after] - eye;
    final edge = b - a;
    final line = (a.dx * edge.dy - a.dy * edge.dx) /
        (ray.dx * edge.dy - ray.dy * edge.dx);
    final hit = model.castRay(
        origin: eye, directionRadians: world, range: range, supportId: support);
    final truth = hit?.distance ?? range;
    // Open sky: the outline follows the range circle with chords, which sag
    // inside it by at most this much.
    final slack = hit == null ? range * (1 - math.cos(gap / 2)) + 1e-6 : 1e-6;
    if (line > truth + 1e-6 || line < truth - slack) {
      wrong.add('ray ${angle.toStringAsFixed(7)}: outline at '
          '${line.toStringAsFixed(5)}, ray ends at ${truth.toStringAsFixed(5)}');
    }
  }
  return wrong;
}

void main() {
  final nativeLibrary = Platform.environment['ICARUS_SVG_NATIVE_LIBRARY'];

  void check(String label, {String? library}) {
    final skip = label == 'native' && library == null
        ? 'Set ICARUS_SVG_NATIVE_LIBRARY.'
        : null;

    test('$label: a wall straddling the seam behind a full circle', () {
      // Found in review: an edge whose angles start just below -pi was not
      // filed in the bins just below pi.
      final model = _model(
          _walls([
            _rectangle(10, 0, 11, 10),
            _rectangle(-21, -21, -20, -20),
          ]),
          nativeLibrary: library);
      expect(_wrong(model, Offset.zero, math.pi, 2 * math.pi, 100), isEmpty);
      // The last ray, at the seam itself, meets the corner on it.
      final outline = model
          .horizontalCone(
              origin: Offset.zero,
              directionRadians: math.pi,
              range: 100,
              apertureRadians: 2 * math.pi)
          .polygon;
      expect(outline.last.distance, closeTo(10, 1e-9));
    }, skip: skip);

    test('$label: a vanishingly narrow cone returns at once', () {
      // Found in review: at 5e-324 radians the bins have no width, and a
      // corner a hair off the cone's direction gave NaN bin indices.
      final model = _model(
          _walls([
            [10, -1e-8, 11, -1e-8, 11, 10, 10, 10]
          ]),
          nativeLibrary: library);
      for (final aperture in [1e-6, 1e-300, 5e-324]) {
        expect(_wrong(model, Offset.zero, 0, aperture, 100), isEmpty,
            reason: 'aperture $aperture');
      }
    }, timeout: const Timeout(Duration(seconds: 20)), skip: skip);

    test('$label: a sliver of wall between two rays', () {
      final model = _model(_walls([_rectangle(10, .03, 11, .05)]),
          nativeLibrary: library);
      expect(_wrong(model, Offset.zero, 0, 1.8, 100), isEmpty);
    }, skip: skip);

    test('$label: real cones end where exact rays do', () {
      // Tight spots against map edges and gaps between walls, plus an even
      // spread over two busy maps.
      final cases = <(String, Offset)>[
        ('haven_svg_height_defense', const Offset(76, 308)),
        ('pearl_svg_height_defense', const Offset(436, 292)),
        ('pearl_svg_height_attack', const Offset(76, 340)),
        ('bind_svg_height_defense', const Offset(164, 276)),
        ('sunset_svg_height_defense', const Offset(141.37, 428)),
        for (final name in [
          'breeze_svg_height_attack',
          'lotus_svg_height_attack'
        ])
          for (var x = 20.0; x < 460; x += 48)
            for (var y = 20.0; y < 460; y += 48) (name, Offset(x, y)),
      ];
      final models = <String, SvgHeightVisibility>{};
      final failures = <String>[];
      var cones = 0;
      for (final (name, at) in cases) {
        final model =
            models[name] ??= _model(_asset(name), nativeLibrary: library);
        final eye = model.standablePointNear(at);
        if (eye == null) continue;
        for (final aperture in [1.8, math.pi, 2 * math.pi]) {
          final direction = (at.dx * 7 + at.dy * 3 + aperture) % (2 * math.pi);
          cones++;
          for (final wrong in _wrong(model, eye, direction, aperture, 140)) {
            failures.add('$name $eye dir $direction aperture $aperture $wrong');
          }
        }
      }
      expect(cones, greaterThan(250));
      expect(failures.take(20), isEmpty);
    }, timeout: const Timeout(Duration(minutes: 5)), skip: skip);
  }

  test('the check finds a wall an outline left out', () {
    // Found in review: on a full circle the first point's angle could come
    // back as pi rather than -pi, and the check then probed nothing.
    final wall = _walls([_rectangle(10, .03, 11, .05)]);
    final real = _model(wall), empty = _model(_walls(const []));
    for (final (direction, aperture) in [
      (0.0, 1.8),
      (0.0, 2 * math.pi),
      (-math.pi / 2, 2 * math.pi),
      (math.pi, 2 * math.pi),
    ]) {
      final missing = empty
          .horizontalCone(
              origin: Offset.zero,
              directionRadians: direction,
              range: 100,
              apertureRadians: aperture)
          .polygon;
      expect(
          _wrongOutline(real, missing, Offset.zero, direction, aperture, 100),
          isNotEmpty,
          reason: 'direction $direction aperture $aperture');
    }
  });

  check('Dart');
  // Desktop runs the same query in native/height.
  check('native', library: nativeLibrary);
}
