import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Path;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

/// A window that only looks into a building nobody can enter is a wall
/// (Dara, 2026-10-02). Sunset's Mid building carries a measured window from
/// about 6 to 7.6 m in both long walls; a cone from the shack roof beside it
/// used to go in one window, across the empty interior and out of the other.
SvgHeightVisibility _model(String name) => SvgHeightVisibility.fromJson(
      jsonDecode(utf8.decode(gzip.decode(
          File('assets/maps/${name}_svg_height_attack.json.gz')
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
  test('the Sunset shack roof does not see through the Mid building', () {
    final model = _model('sunset');
    const roof = Offset(169.7, 303.0);
    // Floor on the far side of the building, in line with both windows.
    const beyond = Offset(242.2, 243.0);
    expect(model.receiverContains(beyond), isTrue);
    expect(model.automaticSupportAt(roof)?.surfaceElevationAt(roof),
        closeTo(5.0, 0.05));
    expect(_sees(model, roof, beyond), isFalse);
  });

  test('Breeze Mid keeps its slanted-roof opening', () {
    // From the 11.8 m perch, a ray through the opening reaches a standing
    // eye on the crate across Mid; the 3D scene clears it all the way.
    final model = _model('breeze');
    const perch = Offset(160, 190);
    const crate = Offset(213.49, 183.84);
    expect(model.automaticSupportAt(perch)?.surfaceElevationAt(perch),
        closeTo(10.0, 0.1));
    expect(_sees(model, perch, crate), isTrue);
  });
}
