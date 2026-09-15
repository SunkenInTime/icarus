import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  test('measure SVG queries on the frozen walking fixture', () async {
    const root = 'E:/IcarusWorldAudit/2026-09-06';
    final candidate = Platform.environment['ICARUS_REGIONAL_CANDIDATE'];
    final asset = File(candidate == null
        ? 'assets/maps/split_svg_height_attack.json.gz'
        : '$candidate/candidate-attack.json.gz');
    final raw = jsonDecode(utf8.decode(gzip.decode(await asset.readAsBytes())))
        as Map<String, dynamic>;
    final fixture = jsonDecode(await File(
            '$root/compact-prototype/native-walking-fixtures-v1/split/walking-144hz.json')
        .readAsString());
    final rows = [];
    {
      final model = SvgHeightVisibility.fromJson(raw);
      final times = <int>[];
      var edges = 0, rays = 0, prep = 0, candidates = 0;
      final slow = [];
      for (var f = 0; f < 420; f += 7) {
        final frame = fixture['frames'][f];
        for (var i = 0; i < 10; i++) {
          final p = frame['positionsSvg'][i], q = frame['poses'][i];
          final cone = model.cone(
              origin:
                  Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()),
              directionRadians: math.atan2(
                  -(q[4] as num).toDouble(), (q[3] as num).toDouble()),
              range: q[5] * 3.9096202760784,
              apertureRadians: (q[6] as num).toDouble());
          times.add(cone.stats.elapsedMicroseconds);
          prep += cone.stats.preparationMicros;
          candidates += cone.stats.candidateMicros;
          if (cone.stats.elapsedMicroseconds > 2000)
            slow.add({
              'frame': f,
              'observer': i,
              'total': cone.stats.elapsedMicroseconds,
              'prep': cone.stats.preparationMicros,
              'candidates': cone.stats.candidateMicros,
              'rays': cone.stats.rayCount,
              'edges': cone.stats.edgeTests,
              'nodes': cone.stats.spatialNodes
            });
          edges += cone.stats.edgeTests;
          rays += cone.stats.rayCount;
        }
      }
      times.sort();
      final row = {
        'median': times[times.length ~/ 2],
        'p95': times[(times.length * .95).floor()],
        'totalMicros': times.reduce((a, b) => a + b),
        'edgeTests': edges,
        'rays': rays,
        'prep': prep,
        'candidates': candidates,
        'slow': slow
      };
      rows.add(row);
      // ignore: avoid_print
      print(jsonEncode({...row, 'slow': slow.take(8).toList()}));
    }
    final output = File(Platform.environment['ICARUS_SPLIT_QUERY_OUTPUT'] ??
        'work/split-svg-query-profile.json');
    expect(output.existsSync(), isFalse);
    await output.parent.create(recursive: true);
    await output.writeAsString(jsonEncode(rows));
  });
}
