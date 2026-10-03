import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

/// Sunset's Mid shack roof is two slopes meeting at a 5 m ridge. They used
/// to stop 0.7 SVG units short of each other, so an agent dragged across the
/// roof dropped to the 2 m ground on the ridge, where a replay shows a player
/// standing. The roof now reaches the ridge from both sides.
void main() {
  const ridges = {
    'attack': [Offset(169.7, 303.007), Offset(163.5, 303.007)],
    'defense': [Offset(246.272, 169.993), Offset(252.4, 169.993)],
  };

  for (final MapEntry(key: side, value: points) in ridges.entries) {
    test('the $side shack ridge stands on the roof', () {
      final model = SvgHeightVisibility.fromJson(
        jsonDecode(utf8.decode(gzip.decode(
            File('assets/maps/sunset_svg_height_$side.json.gz')
                .readAsBytesSync()))) as Map<String, dynamic>,
      );
      for (final point in points) {
        final support = model.automaticSupportAt(point);
        expect(support?.surfaceElevationAt(point), closeTo(5.0, 0.05),
            reason: 'at $point');
      }
    });
  }
}
