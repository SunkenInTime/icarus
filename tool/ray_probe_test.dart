import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  test('probe', () {
    final env = Platform.environment;
    final map = env['ICARUS_PROBE_MAP']!, side = env['ICARUS_PROBE_SIDE'] ?? 'attack';
    final p = env['ICARUS_PROBE_POSE']!.split(',').map(double.parse).toList();
    final model = SvgHeightVisibility.fromJson(jsonDecode(utf8.decode(gzip.decode(
        File('${env['ICARUS_PROBE_DIR'] ?? 'assets/maps'}/${map}_svg_height_$side.json.gz').readAsBytesSync()))));
    final origin = Offset(p[0], p[1]);
    final support = model.automaticSupportAt(origin);
    final centre = p[2] * math.pi / 180;
    final half = 51.5 * math.pi / 180;
    final eye = (support?.surfaceElevationAt(origin) ?? model.ground!.heightAt(origin)!) + 1.75;
    print('support=${support?.id} eye=$eye');
    var longest = 0.0; var longestDir = 0.0;
    for (var i = 0; i <= 400; i++) {
      final dir = centre - half + 2 * half * i / 400;
      final hit = model.castRay(origin: origin, directionRadians: dir, range: 120, supportId: support?.id);
      final d = hit?.distance ?? 120;
      if (d > longest) { longest = d; longestDir = dir; }
    }
    print('longest ray ${longest.toStringAsFixed(1)} at ${(longestDir * 180 / math.pi).toStringAsFixed(2)} deg');
    final dx = math.cos(longestDir), dy = math.sin(longestDir);
    var wasInside = true;
    for (var t = 0.0; t < longest; t += 0.25) {
      final q = origin + Offset(dx * t, dy * t);
      final inside = model.receiverContains(q);
      if (inside != wasInside) {
        print('  receiver ${inside ? 'entered' : 'left'} at t=${t.toStringAsFixed(1)} (${q.dx.toStringAsFixed(1)},${q.dy.toStringAsFixed(1)})');
        wasInside = inside;
      }
    }
    final seen = <String>{};
    for (var t = 0.0; t < longest; t += 0.25) {
      final q = origin + Offset(dx * t, dy * t);
      for (final w in model.walls) {
        if (w.contains(q) && seen.add(w.id)) {
          print('  t=${t.toStringAsFixed(1)} at (${q.dx.toStringAsFixed(1)},${q.dy.toStringAsFixed(1)}) ${w.id} floor=${w.floorElevationMeters} bands=${w.bands.map((b) => '[${b.bottom},${b.top}]').join()} blocks=${w.blocks(eye)}');
        }
      }
    }
    // walls near the ray corridor that the ray does NOT enter
    print('walls within 1.5 units of the ray but never entered:');
    for (final w in model.walls) {
      if (seen.contains(w.id)) continue;
      var near = false;
      for (var t = 0.0; t < longest && !near; t += 0.5) {
        final q = origin + Offset(dx * t, dy * t);
        for (final ring in w.rings) {
          for (final v in ring) { if ((v - q).distance < 1.5) { near = true; break; } }
          if (near) break;
        }
      }
      if (near) print('  ${w.id} floor=${w.floorElevationMeters} bands=${w.bands.map((b) => '[${b.bottom},${b.top}]').join()} blocks=${w.blocks(eye)}');
    }
  });
}
