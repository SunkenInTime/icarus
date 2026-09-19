import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

// Dara's ruling (haven-garage-window-review-2026-09-19.json in the
// icarus-vision-pipeline archive):
// the C Garage window is see-through from the garage floor, crate included.
void main() {
  final alignment = jsonDecode(File(
          'E:/IcarusWorldAudit/2026-09-06/tactical-alignment-sides-v1/haven.json')
      .readAsStringSync());
  Offset mirror(Offset p) {
    final a = (alignment['nativeToAttackSvg'] as List)
        .map((r) => (r as List).map((v) => (v as num).toDouble()).toList())
        .toList();
    final d = (alignment['nativeToDefenseSvg'] as List)
        .map((r) => (r as List).map((v) => (v as num).toDouble()).toList())
        .toList();
    final det = a[0][0] * a[1][1] - a[0][1] * a[1][0];
    final x = p.dx - a[0][2], y = p.dy - a[1][2];
    final nx = (a[1][1] * x - a[0][1] * y) / det;
    final ny = (-a[1][0] * x + a[0][0] * y) / det;
    return Offset(d[0][0] * nx + d[0][1] * ny + d[0][2],
        d[1][0] * nx + d[1][1] * ny + d[1][2]);
  }

  for (final side in ['attack', 'defense']) {
    test('Haven $side garage floor sees through the garage window', () {
      final model = SvgHeightVisibility.fromJson(jsonDecode(utf8.decode(gzip
          .decode(File('assets/maps/haven_svg_height_$side.json.gz')
              .readAsBytesSync()))));
      var origin = const Offset(131.651, 246.013);
      var direction = -1.445;
      if (side == 'defense') {
        origin = mirror(origin);
        direction += math.pi;
      }
      expect(model.receiverContains(origin), isTrue);
      final hit = model.castRay(
          origin: origin,
          directionRadians: direction,
          range: 60,
          absoluteEyeElevationMeters: 2.75);
      expect(hit == null || hit.distance > 45, isTrue,
          reason: 'stopped at ${hit?.wallId} ${hit?.distance}');
    });
  }
}
