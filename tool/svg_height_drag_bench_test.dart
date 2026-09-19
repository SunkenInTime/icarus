// CPU cost of one dragged cone, stage by stage, on the UI thread.
// Env: ICARUS_BENCH_MAP=pearl ICARUS_SVG_NATIVE_LIBRARY=<dll>
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:icarus/view_cone/svg_height_cone_cache.dart';

void main() {
  test('drag bench', () {
    final env = Platform.environment;
    final map = env['ICARUS_BENCH_MAP'] ?? 'pearl';
    final model = SvgHeightVisibility.fromJson(jsonDecode(utf8.decode(gzip.decode(
        File('assets/maps/${map}_svg_height_attack.json.gz').readAsBytesSync()))));
    final native = model.enableNativeAcceleration(libraryPath: env['ICARUS_SVG_NATIVE_LIBRARY']);
    print('map $map native=$native walls=${model.walls.length} supports=${model.supports.length}');
    final cache = SvgHeightConeCache(model);
    // a receiver path like the widget builds
    Path ringsPath(List<List<Offset>> rings, bool evenOdd) {
      final p = Path()..fillType = evenOdd ? PathFillType.evenOdd : PathFillType.nonZero;
      for (final r in rings) { p.addPolygon(r, true); }
      return p;
    }
    Path? receiver;
    for (final r in model.receivers) {
      final next = ringsPath(r.rings, r.evenOdd);
      receiver = receiver == null ? next : Path.combine(PathOperation.union, receiver, next);
    }
    // poses: walk across the receiver on a grid, keep those on the floor
    final poses = <Offset>[];
    final rnd = math.Random(1);
    while (poses.length < 400) {
      final p = Offset(rnd.nextDouble() * 470, rnd.nextDouble() * 470);
      if (model.receiverContains(p) && model.ground?.heightAt(p) != null) poses.add(p);
    }
    final t = <String, int>{};
    void tick(String k, Stopwatch w) { t[k] = (t[k] ?? 0) + w.elapsedMicroseconds; w.reset(); }
    var nativeMicros = 0.0, points = 0, pathPoints = 0, rays = 0, edges = 0, prep = 0.0, cand = 0.0;
    final w = Stopwatch()..start();
    final transform = Float64List(16)..[0] = 2..[5] = 2..[10] = 1..[15] = 1;
    for (var i = 0; i < poses.length; i++) {
      final o = poses[i];
      w.reset();
      model.receiverContains(o); model.ground!.heightAt(o); tick('receiver+ground', w);
      final s = model.standingSupportAt(o); tick('standingSupportAt', w);
      final c = cache.cone(observerId: 'x', origin: o, directionRadians: i * 0.7, range: double.parse(env['ICARUS_BENCH_RANGE'] ?? '100'), apertureRadians: 1.8, supportId: s?.id);
      tick('cone()', w);
      nativeMicros += c.cone.stats.nativeMicros; points += c.cone.polygon.length; rays += c.cone.stats.rayCount; edges += c.cone.stats.edgeTests; prep += c.cone.stats.preparationMicros; cand += c.cone.stats.candidateMicros;
      final vis = c.cone.visibilityPath ?? (Path()..addPolygon(c.cone.polygon, true));
      final v2 = vis.transform(transform); tick('visibility path', w);
      final r2 = receiver!.transform(transform); tick('receiver transform', w);
      pathPoints += c.cone.polygon.length; if (v2.getBounds().isEmpty || r2.getBounds().isEmpty) print('?');
    }
    final n = poses.length;
    print('per cone (us): ' + t.entries.map((e) => '${e.key}=${(e.value / n).round()}').join('  '));
    print('native inside cone(): ${(nativeMicros / n).round()} us; polygon points avg ${(points / n).round()}');
    print('native split: arc rays ${(prep / n).round()} us, events ${(cand / n).round()} us, final rays ${((nativeMicros - prep - cand) / n).round()} us');
    print('rays avg ${(rays / n).round()} edgeTests avg ${(edges / n).round()}');
    print('cache stats: queries=${cache.queryCount} reuse=${cache.reuseCount}');
  });
}
