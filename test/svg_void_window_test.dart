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
void main() {
  test('the Sunset shack roof does not see through the Mid building', () {
    final model = SvgHeightVisibility.fromJson(
      jsonDecode(utf8.decode(gzip.decode(
          File('assets/maps/sunset_svg_height_attack.json.gz')
              .readAsBytesSync()))) as Map<String, dynamic>,
    );
    const roof = Offset(169.7, 303.0);
    // Floor on the far side of the building, in line with both windows.
    const beyond = Offset(242.2, 243.0);
    expect(model.receiverContains(beyond), isTrue);

    final support = model.automaticSupportAt(roof);
    expect(support?.surfaceElevationAt(roof), closeTo(5.0, 0.05));
    final toward = beyond - roof;
    final cone = model.cone(
      origin: roof,
      directionRadians: math.atan2(toward.dy, toward.dx),
      range: 120,
      apertureRadians: math.pi / 6,
      supportId: support!.id,
    );
    final visible =
        cone.visibilityPath ?? (Path()..addPolygon(cone.polygon, true));
    expect(visible.contains(beyond), isFalse);
  });
}
