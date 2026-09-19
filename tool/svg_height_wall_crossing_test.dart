import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
void main() {
  test('cone along a path that grazes walls', () {
    final env = Platform.environment;
    final model = SvgHeightVisibility.fromJson(jsonDecode(utf8.decode(gzip.decode(
        File('assets/maps/haven_svg_height_attack.json.gz').readAsBytesSync()))));
    model.enableNativeAcceleration(libraryPath: env['ICARUS_SVG_NATIVE_LIBRARY']);
    // Garage to Garden platform, the benchmark's drag, sampled finely.
    const a = Offset(131.7, 246), b = Offset(254.6, 371.1);
    var offFloor = 0, insideWall = 0, ok = 0, moved = 0;
    for (var i = 0; i <= 600; i++) {
      final p = Offset.lerp(a, b, i / 600)!;
      final q = model.standablePointNear(p);
      if (q == null) { offFloor++; continue; }
      final c = model.cone(origin: q, directionRadians: -1.4, range: 140, apertureRadians: 1.8, supportId: model.automaticSupportAt(q)?.id);
      if (c.polygon.length < 3) insideWall++; else ok++;
      if (q != p) moved++;
    }
    print('samples 601 with nudge: cone drawn $ok, hidden (no standable point within 2.5) $offFloor, still inside wall $insideWall, nudged $moved');
  });
}
