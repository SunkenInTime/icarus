// Renders before/after cone crops for reviewing wall-height changes.
//
// Env:
//   ICARUS_GALLERY_MAP=pearl ICARUS_GALLERY_SIDE=attack
//   ICARUS_GALLERY_CANDIDATE=work/wall-height-audit/candidate   (optional)
//   ICARUS_GALLERY_POSES="255,278,90;120,200,0"  (svg x, svg y, facing degrees)
//   ICARUS_GALLERY_OUT=build/gallery
// Each pose writes <out>/<map>_<side>_<i>.png: left = bundled asset, right =
// candidate asset (or the same asset when none is given). Gold = wall ink,
// dark = receiver, blue cone = visibility at the automatic standing level.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('render cone gallery', () async {
    final env = Platform.environment;
    final map = env['ICARUS_GALLERY_MAP'] ?? 'pearl';
    final side = env['ICARUS_GALLERY_SIDE'] ?? 'attack';
    final candidate = env['ICARUS_GALLERY_CANDIDATE'];
    final out = Directory(env['ICARUS_GALLERY_OUT'] ?? 'build/gallery');
    out.createSync(recursive: true);
    final poses = (env['ICARUS_GALLERY_POSES'] ?? '255,278,90')
        .split(';')
        .map((p) => p.split(',').map(double.parse).toList())
        .toList();
    SvgHeightVisibility load(String dir) => SvgHeightVisibility.fromJson(
        jsonDecode(utf8.decode(gzip.decode(
            File('$dir/${map}_svg_height_$side.json.gz').readAsBytesSync()))));
    final before = load(env['ICARUS_GALLERY_BEFORE'] ?? 'assets/maps');
    final after = candidate == null ? before : load(candidate);
    for (var i = 0; i < poses.length; i++) {
      final origin = ui.Offset(poses[i][0], poses[i][1]);
      final facing = poses[i][2] * math.pi / 180;
      final image = await _render(before, after, origin, facing);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('${out.path}/${map}_${side}_$i.png')
          .writeAsBytesSync(bytes!.buffer.asUint8List());
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}

Future<ui.Image> _render(SvgHeightVisibility before, SvgHeightVisibility after,
    ui.Offset origin, double facing) async {
  const half = 60.0, scale = 6.0, range = 70.0;
  final size = ui.Size(half * 2 * scale * 2 + 8, half * 2 * scale);
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)
    ..drawRect(ui.Offset.zero & size, ui.Paint()..color = const ui.Color(0xff000000));
  for (var pane = 0; pane < 2; pane++) {
    final model = pane == 0 ? before : after;
    canvas.save();
    canvas.translate(pane * (half * 2 * scale + 8), 0);
    canvas.clipRect(ui.Rect.fromLTWH(0, 0, half * 2 * scale, half * 2 * scale));
    canvas.scale(scale);
    canvas.translate(half - origin.dx, half - origin.dy);
    for (final r in model.receivers) {
      canvas.drawPath(_path(r.rings, r.evenOdd), ui.Paint()..color = const ui.Color(0xff241507));
    }
    final support = model.standingSupportAt(origin);
    final cone = model.cone(
        origin: origin,
        directionRadians: facing,
        range: range,
        apertureRadians: math.pi / 2,
        supportId: support?.id);
    if (cone.polygon.length >= 3) {
      final path = cone.visibilityPath ?? (ui.Path()..addPolygon(cone.polygon, true));
      canvas.drawPath(path, ui.Paint()..color = const ui.Color(0x8060a5fa));
    }
    final eye = cone.eyeElevationMeters ?? 0;
    for (final w in model.walls) {
      final blocks = w.blocks(eye);
      canvas.drawPath(_path(w.rings, w.evenOdd),
          ui.Paint()..color = blocks ? const ui.Color(0xffb27c40) : const ui.Color(0xff5a4a2a));
    }
    canvas.drawCircle(origin, 1.2, ui.Paint()..color = const ui.Color(0xffffffff));
    canvas.restore();
    final label = ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: 14))
      ..pushStyle(ui.TextStyle(color: const ui.Color(0xffffffff)))
      ..addText('${pane == 0 ? 'before' : 'after'}  eye ${eye.toStringAsFixed(2)} m'
          '${support == null ? '' : '  on ${support.id}'}');
    canvas.drawParagraph(
        label.build()..layout(const ui.ParagraphConstraints(width: 700)),
        ui.Offset(pane * (half * 2 * scale + 8) + 6, 6));
  }
  return recorder.endRecording().toImage(size.width.ceil(), size.height.ceil());
}

ui.Path _path(List<List<ui.Offset>> rings, bool evenOdd) {
  final path = ui.Path()..fillType = evenOdd ? ui.PathFillType.evenOdd : ui.PathFillType.nonZero;
  for (final ring in rings) {
    path.addPolygon(ring, true);
  }
  return path;
}
