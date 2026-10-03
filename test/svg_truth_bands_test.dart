import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Path;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

/// Drawn walls whose bands said open where the 3D scene is solid at the eye
/// that looked through them (2026-10-02, see docs/vision-model.md). The real
/// face sat more than half a metre off the ink, outside the old ray probe.
SvgHeightVisibility _model(String name, String side) =>
    SvgHeightVisibility.fromJson(
      jsonDecode(utf8.decode(gzip.decode(
          File('assets/maps/${name}_svg_height_$side.json.gz')
              .readAsBytesSync()))) as Map<String, dynamic>,
    );

/// Whether an agent standing at [from] on its default level sees [target].
bool _sees(SvgHeightVisibility model, Offset from, Offset target) {
  final support = model.automaticSupportAt(from);
  final toward = target - from;
  final cone = model.cone(
    origin: from,
    directionRadians: math.atan2(toward.dy, toward.dx),
    range: 120,
    apertureRadians: math.pi / 6,
    supportId: support?.id,
  );
  final visible =
      cone.visibilityPath ?? (Path()..addPolygon(cone.polygon, true));
  return visible.contains(target);
}

void main() {
  test('the Lotus defense platform wall stops a standing cone', () {
    // Dara's replay, round 2 at 0:11: Chamber on the 3 m platform looked
    // through p7-stroke-3-local-1, which had no band below 20.75 m.
    final model = _model('lotus', 'defense');
    expect(_sees(model, const Offset(425, 325.4), const Offset(425, 346)),
        isFalse);
    expect(
        _sees(model, const Offset(425, 325.4), const Offset(425, 335)), isTrue,
        reason: 'the platform in front of the wall stays lit');
  });

  test('Bind B container blocks a cone from the ground beside it', () {
    // The container outline carried no bands at all.
    final model = _model('bind', 'attack');
    expect(
        _sees(model, const Offset(107.5, 158.5), const Offset(71.59, 147.35)),
        isFalse);
    expect(
        _sees(model, const Offset(107.5, 158.5), const Offset(70, 140)), isTrue,
        reason: 'the floor past the end of the container stays lit');
  });

  test('the Haven garage window stays open from the garage floor', () {
    // Dara, 2026-09-19: as a simplification the C Garage window is
    // see-through from the floor. The truth pass raised its sill from the
    // 3D scene; reviewed rulings are put back (restore_reviewed.py).
    final model = _model('haven', 'attack');
    expect(
        _sees(model, const Offset(131.651, 246.013),
            const Offset(137.17, 202.36)),
        isTrue);
  });
}
