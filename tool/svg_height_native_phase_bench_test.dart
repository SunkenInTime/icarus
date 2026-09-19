import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
void main() {
  test('phases', () {
    final env = Platform.environment;
    final model = SvgHeightVisibility.fromJson(jsonDecode(utf8.decode(gzip.decode(
        File('assets/maps/haven_svg_height_attack.json.gz').readAsBytesSync()))));
    model.enableNativeAcceleration(libraryPath: env['ICARUS_SVG_NATIVE_LIBRARY']);
    final range = double.parse(env['ICARUS_BENCH_RANGE'] ?? '140');
    final rnd = math.Random(1);
    final poses = <Offset>[];
    while (poses.length < 300) {
      final p = Offset(rnd.nextDouble() * 390, rnd.nextDouble() * 470);
      if (model.receiverContains(p) && model.ground?.heightAt(p) != null) poses.add(p);
    }
    var prep = 0.0, cand = 0.0, total = 0.0, rays = 0, candidates = 0;
    for (var i = 0; i < poses.length; i++) {
      final c = model.cone(origin: poses[i], directionRadians: i * 0.7, range: range, apertureRadians: 1.8, supportId: model.automaticSupportAt(poses[i])?.id);
      prep += c.stats.preparationMicros ?? 0; cand += c.stats.candidateMicros ?? 0; total += c.stats.nativeMicros; rays += c.stats.rayCount;
    }
    final n = poses.length;
    print('native phases (us): arc rays ${(prep / n).round()}  events ${((cand - prep) / n).round()}  final ${((total - cand) / n).round()}  total ${(total / n).round()}  rays ${(rays / n).round()}');
  });
}
