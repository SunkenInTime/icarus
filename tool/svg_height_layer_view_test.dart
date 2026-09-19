// Diagnostic render of a map region: ground height as grey, wall pieces
// coloured by which of two eye heights they block, and cones for poses.
// Env: ICARUS_LAYER_MAP, ICARUS_LAYER_SIDE, ICARUS_LAYER_BOX="x0,y0,x1,y1",
//      ICARUS_LAYER_EYES="4.25,7.75", ICARUS_LAYER_POSES="x,y,deg,eye;...",
//      ICARUS_LAYER_OUT=build/layer.png
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('layer view', () async {
    final env = Platform.environment;
    final map = env['ICARUS_LAYER_MAP'] ?? 'pearl', side = env['ICARUS_LAYER_SIDE'] ?? 'attack';
    final box = (env['ICARUS_LAYER_BOX'] ?? '100,130,180,200').split(',').map(double.parse).toList();
    final eyes = (env['ICARUS_LAYER_EYES'] ?? '4.25,7.75').split(',').map(double.parse).toList();
    final poses = (env['ICARUS_LAYER_POSES'] ?? '').split(';').where((p) => p.isNotEmpty)
        .map((p) => p.split(',').map(double.parse).toList()).toList();
    final model = SvgHeightVisibility.fromJson(jsonDecode(utf8.decode(gzip.decode(
        File('${env['ICARUS_LAYER_DIR'] ?? 'assets/maps'}/${map}_svg_height_$side.json.gz').readAsBytesSync()))));
    const scale = 9.0;
    final w = ((box[2] - box[0]) * scale).ceil(), h = ((box[3] - box[1]) * scale).ceil();
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec)..drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), ui.Paint()..color = const ui.Color(0xff000000));
    canvas.scale(scale);
    canvas.translate(-box[0], -box[1]);
    // ground as grey, sampled per cell
    double lo = 1e9, hi = -1e9;
    final cells = <List<double>>[];
    for (var y = box[1]; y < box[3]; y += 0.5) {
      for (var x = box[0]; x < box[2]; x += 0.5) {
        final p = ui.Offset(x + 0.25, y + 0.25);
        if (!model.receiverContains(p)) continue;
        final g = model.ground?.heightAt(p);
        if (g == null) continue;
        cells.add([x, y, g]); lo = math.min(lo, g); hi = math.max(hi, g);
      }
    }
    for (final c in cells) {
      final t = hi > lo ? (c[2] - lo) / (hi - lo) : 0.5;
      final v = (40 + 160 * t).round();
      canvas.drawRect(ui.Rect.fromLTWH(c[0], c[1], 0.5, 0.5), ui.Paint()..color = ui.Color.fromARGB(255, v, v, v));
    }
    for (final wall in model.walls) {
      final a = wall.blocks(eyes[0]), b = wall.blocks(eyes[1]);
      final color = a && b ? const ui.Color(0xffffffff) : a ? const ui.Color(0xffff4444) : b ? const ui.Color(0xff44aaff) : const ui.Color(0xff806040);
      final path = ui.Path()..fillType = wall.evenOdd ? ui.PathFillType.evenOdd : ui.PathFillType.nonZero;
      for (final ring in wall.rings) { path.addPolygon(ring, true); }
      canvas.drawPath(path, ui.Paint()..color = color);
    }
    for (final p in poses) {
      final origin = ui.Offset(p[0], p[1]);
      final cone = model.cone(origin: origin, directionRadians: p[2] * math.pi / 180, range: 80, apertureRadians: 103 * math.pi / 180, absoluteEyeElevationMeters: p[3]);
      if (cone.polygon.length >= 3) {
        canvas.drawPath(cone.visibilityPath ?? (ui.Path()..addPolygon(cone.polygon, true)), ui.Paint()..color = const ui.Color(0x6000ff88));
      }
      canvas.drawCircle(origin, 1.0, ui.Paint()..color = const ui.Color(0xff00ff00));
    }
    final img = await rec.endRecording().toImage(w, h);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    File(env['ICARUS_LAYER_OUT'] ?? 'build/layer.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    print('ground range $lo..$hi');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
