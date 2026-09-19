// Ranks standing spots by how much the view cone changes between two
// bundled models, e.g. a candidate that demotes small supports and the
// shipped asset. Env: ICARUS_FLIP_MAP, ICARUS_FLIP_POSES (json: map ->
// [{x,y,...}]), ICARUS_FLIP_BEFORE, ICARUS_FLIP_AFTER, ICARUS_FLIP_OUT.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

double _area(List<Offset> p) {
  var s = 0.0;
  for (var i = 0; i < p.length; i++) {
    final a = p[i], b = p[(i + 1) % p.length];
    s += a.dx * b.dy - b.dx * a.dy;
  }
  return s.abs() / 2;
}

void main() {
  test('rank flips', () {
    final env = Platform.environment;
    final map = env['ICARUS_FLIP_MAP'] ?? 'icebox';
    SvgHeightVisibility load(String dir) => SvgHeightVisibility.fromJson(
        jsonDecode(utf8.decode(gzip.decode(
            File('$dir/${map}_svg_height_attack.json.gz').readAsBytesSync()))));
    final before = load(env['ICARUS_FLIP_BEFORE'] ?? 'work/small-supports/candidate');
    final after = load(env['ICARUS_FLIP_AFTER'] ?? 'assets/maps');
    final poses = (jsonDecode(File(env['ICARUS_FLIP_POSES'] ?? 'work/small-supports/flip-poses.json')
        .readAsStringSync()) as Map)[map] as List;
    final rows = <Map<String, Object?>>[];
    for (final pose in poses) {
      final origin = Offset((pose['x'] as num).toDouble(), (pose['y'] as num).toDouble());
      var best = 0.0, bestDir = 0.0, bestA = 0.0, bestB = 0.0;
      for (var k = 0; k < 8; k++) {
        final dir = k * math.pi / 4;
        double area(SvgHeightVisibility m) {
          final cone = m.cone(
              origin: origin, directionRadians: dir, range: 100,
              apertureRadians: 103 * math.pi / 180,
              supportId: m.automaticSupportAt(origin)?.id);
          return cone.polygon.length < 3 ? 0 : _area(cone.polygon);
        }
        final a = area(before), b = area(after);
        final d = (b - a).abs() / math.max(1, math.max(a, b));
        if (d > best) { best = d; bestDir = dir; bestA = a; bestB = b; }
      }
      rows.add({...pose, 'change': best, 'facingDeg': bestDir * 180 / math.pi,
                'floorArea': bestA, 'propArea': bestB});
    }
    rows.sort((a, b) => (b['change'] as double).compareTo(a['change'] as double));
    final out = File(env['ICARUS_FLIP_OUT'] ?? 'work/small-supports/flip-rank-$map.json');
    out.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(rows));
    for (final r in rows.take(8)) {
      print('${r['support']} (${r['x']},${r['y']}) step ${r['step']} facing ${(r['facingDeg'] as double).round()} change ${(r['change'] as double).toStringAsFixed(2)} floor ${(r['floorArea'] as double).round()} prop ${(r['propArea'] as double).round()}');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
