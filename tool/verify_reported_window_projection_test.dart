// Generate the reference grid with scripts/verify_reported_window_projection.py.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  final folder = Platform.environment['ICARUS_SIGHTLINE_MODELS'] ??
      'work/reported-sightlines-final-v4';
  final library = Platform.environment['ICARUS_HEIGHT_LIBRARY'] ??
      'build/sightline/runner/Profile/icarus_height.dll';
  for (final side in ['attack', 'defense']) {
    test('$side window agrees with independent 3D segment intersections',
        () async {
      final bytes = File('$folder/haven-$side.json.gz').readAsBytesSync();
      final model = SvgHeightVisibility.fromJson(
          jsonDecode(utf8.decode(gzip.decode(bytes))));
      expect(model.enableNativeAcceleration(libraryPath: library), isTrue);
      final proof = jsonDecode(
          File('$folder/window-projection-proof-$side.json')
              .readAsStringSync());
      final hash = (await Sha256().hash(bytes))
          .bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(hash, proof['modelSha256']);
      expect(proof['failures'], isEmpty);
      final origin = Offset(proof['origin'][0], proof['origin'][1]);
      SvgVisibilityCone query() => model.cone(
          origin: origin,
          directionRadians: side == 'attack' ? math.pi / 2 : -math.pi / 2,
          range: 100,
          apertureRadians: math.pi,
          absoluteEyeElevationMeters: proof['eye']);
      final cone = query();
      expect(cone.visibilityPath, isNotNull);
      for (final row in proof['cases']) {
        final point = Offset(row['point'][0], row['point'][1]);
        expect(cone.visibilityPath!.contains(point), row['visible'],
            reason: '$side $point');
      }
      final timings = [
        for (var i = 0; i < 20; i++) query().stats.elapsedMicroseconds
      ]..sort();
      stdout.writeln('$side: ${proof["checks"]} points pass; warm median '
          '${timings[10]} us, p95 ${timings[18]} us in the test process.');
    });
  }
}
