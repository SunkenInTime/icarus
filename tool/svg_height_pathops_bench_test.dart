import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
void main() {
  test('pathops', () {
    final env = Platform.environment;
    final model = SvgHeightVisibility.fromJson(jsonDecode(utf8.decode(gzip.decode(
        File('assets/maps/haven_svg_height_attack.json.gz').readAsBytesSync()))));
    model.enableNativeAcceleration(libraryPath: env['ICARUS_SVG_NATIVE_LIBRARY']);
    Path rings(List<List<Offset>> rs, bool evenOdd) { final p = Path()..fillType = evenOdd ? PathFillType.evenOdd : PathFillType.nonZero; for (final r in rs) { p.addPolygon(r, true); } return p; }
    Path? receiver;
    for (final r in model.receivers) { final n = rings(r.rings, r.evenOdd); receiver = receiver == null ? n : Path.combine(PathOperation.union, receiver, n); }
    final rnd = math.Random(1); final poses = <Offset>[];
    while (poses.length < 200) { final p = Offset(rnd.nextDouble() * 390, rnd.nextDouble() * 470); if (model.receiverContains(p) && model.ground?.heightAt(p) != null) poses.add(p); }
    final identity = Float64List(16)..[0] = 1..[5] = 1..[10] = 1..[15] = 1;
    var combine = 0, verts = 0; final w = Stopwatch();
    for (var i = 0; i < poses.length; i++) {
      final c = model.cone(origin: poses[i], directionRadians: i * .7, range: 140, apertureRadians: 1.8, supportId: model.automaticSupportAt(poses[i])?.id);
      final outline = c.outlinePath(identity);
      w.reset(); w.start();
      final clipped = Path.combine(PathOperation.intersect, outline, receiver!);
      w.stop(); combine += w.elapsedMicroseconds;
      final m = clipped.computeMetrics(); var n = 0; for (final _ in m) { n++; } verts += n;
    }
    print('Path.combine(intersect) cone x receiver: ${(combine / poses.length).round()} us per cone, contours avg ${(verts / poses.length).toStringAsFixed(1)}');
  });
}
