import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

/// A cone's outline is a fan of rays from the eye joined by straight lines.
/// The cone query skips every ray it can prove would land in the middle of a
/// wall another ray already covers. If it ever skips a real corner, the line
/// joining its neighbours cuts across a wall. So between every two outline
/// points, a single exact ray must meet a wall exactly where the line is.
SvgHeightVisibility _model(String name, {String? nativeLibrary}) {
  final model = SvgHeightVisibility.fromJson(jsonDecode(utf8.decode(
          gzip.decode(File('assets/maps/$name.json.gz').readAsBytesSync())))
      as Map<String, dynamic>);
  if (nativeLibrary != null) {
    expect(model.enableNativeAcceleration(libraryPath: nativeLibrary), isTrue);
  }
  return model;
}

/// Where the ray from [origin] along [direction] crosses the line [a]-[b].
double _along(Offset origin, Offset direction, Offset a, Offset b) {
  final edge = b - a, relative = a - origin;
  final determinant = direction.dx * edge.dy - direction.dy * edge.dx;
  return (relative.dx * edge.dy - relative.dy * edge.dx) / determinant;
}

/// The places on the outline where it disagrees with exact rays.
List<String> _wrongChords(SvgHeightVisibility model, Offset eye,
    double direction, double aperture, double range) {
  final support = model.automaticSupportAt(eye)?.id;
  final outline = model
      .horizontalCone(
          origin: eye,
          directionRadians: direction,
          range: range,
          apertureRadians: aperture,
          supportId: support)
      .polygon;
  final wrong = <String>[];
  for (var i = 1; i + 1 < outline.length; i++) {
    final a = outline[i] - eye, b = outline[i + 1] - eye;
    final from = math.atan2(a.dy, a.dx), to = math.atan2(b.dy, b.dx);
    var turn = to - from;
    if (turn > math.pi) turn -= 2 * math.pi;
    if (turn < -math.pi) turn += 2 * math.pi;
    // The sliver beside a silhouette is a chord between the corner ray and
    // the ray just past it, by design.
    if (turn.abs() < 1e-7) continue;
    final angle = from + turn / 2;
    final ray = Offset(math.cos(angle), math.sin(angle));
    final hit = model.castRay(
        origin: eye, directionRadians: angle, range: range, supportId: support);
    // Open sky: the outline follows the range circle with chords.
    if (hit == null) continue;
    final line = _along(eye, ray, outline[i], outline[i + 1]);
    if ((line - hit.distance).abs() > 1e-6) {
      wrong.add('ray ${angle.toStringAsFixed(6)}: outline at '
          '${line.toStringAsFixed(4)}, wall at ${hit.distance.toStringAsFixed(4)}');
    }
  }
  return wrong;
}

void main() {
  // Tight spots against map edges and gaps between walls, plus an even
  // spread over two busy maps.
  final cases = <(String, Offset)>[
    ('haven_svg_height_defense', const Offset(76, 308)),
    ('pearl_svg_height_defense', const Offset(436, 292)),
    ('pearl_svg_height_attack', const Offset(76, 340)),
    ('bind_svg_height_defense', const Offset(164, 276)),
    ('sunset_svg_height_defense', const Offset(141.37, 428)),
    for (final name in ['breeze_svg_height_attack', 'lotus_svg_height_attack'])
      for (var x = 20.0; x < 460; x += 32)
        for (var y = 20.0; y < 460; y += 32) (name, Offset(x, y)),
  ];
  void check(String label, {String? nativeLibrary}) {
    test(
        'every line of a $label cone outline lies on the wall an exact ray '
        'meets', () {
      final models = <String, SvgHeightVisibility>{};
      final failures = <String>[];
      var cones = 0;
      for (final (name, at) in cases) {
        final model =
            models[name] ??= _model(name, nativeLibrary: nativeLibrary);
        final eye = model.standablePointNear(at);
        if (eye == null) continue;
        for (final (aperture, range) in [
          (1.8, 140.0),
          (math.pi, 140.0),
          (2 * math.pi, 140.0),
        ]) {
          final direction = (at.dx * 7 + at.dy * 3 + aperture) % (2 * math.pi);
          cones++;
          for (final wrong
              in _wrongChords(model, eye, direction, aperture, range)) {
            failures.add('$name $eye dir $direction aperture $aperture $wrong');
          }
        }
      }
      expect(cones, greaterThan(600));
      expect(failures, isEmpty);
    },
        timeout: const Timeout(Duration(minutes: 5)),
        skip: label == 'native' && nativeLibrary == null
            ? 'Set ICARUS_SVG_NATIVE_LIBRARY.'
            : false);
  }

  check('Dart');
  // Desktop runs the same query in native/height.
  check('native',
      nativeLibrary: Platform.environment['ICARUS_SVG_NATIVE_LIBRARY']);
}
