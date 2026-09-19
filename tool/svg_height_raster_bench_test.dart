// Relative raster cost of the two painting strategies in the software
// rasteriser: two clips plus a circle, versus one clip plus a filled path.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart' show Colors, RadialGradient;
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('raster', () async {
    final env = Platform.environment;
    final model = SvgHeightVisibility.fromJson(jsonDecode(utf8.decode(gzip.decode(
        File('assets/maps/haven_svg_height_attack.json.gz').readAsBytesSync()))));
    model.enableNativeAcceleration(libraryPath: env['ICARUS_SVG_NATIVE_LIBRARY']);
    Path rings(List<List<Offset>> rs, bool evenOdd) { final p = Path()..fillType = evenOdd ? PathFillType.evenOdd : PathFillType.nonZero; for (final r in rs) { p.addPolygon(r, true); } return p; }
    Path? receiver;
    for (final r in model.receivers) { final n = rings(r.rings, r.evenOdd); receiver = receiver == null ? n : Path.combine(PathOperation.union, receiver, n); }
    const scale = 4.0; // screen pixels per svg unit, roughly a zoomed-in cone
    final t = Float64List(16)..[0] = scale..[5] = scale..[10] = 1..[15] = 1;
    final screenReceiver = receiver!.transform(t);
    final origin = const Offset(131.7, 246);
    final c = model.cone(origin: origin, directionRadians: -1.4, range: 140, apertureRadians: 1.8, supportId: model.automaticSupportAt(origin)?.id);
    final outline = c.outlinePath(t);
    final apex = origin * scale; final radius = 140 * scale;
    final paint = Paint()..shader = RadialGradient(colors: [const Color.fromARGB(255, 147, 147, 147).withValues(alpha: .35), Colors.transparent], stops: const [0, 1]).createShader(Rect.fromCircle(center: apex, radius: radius));
    Future<int> time(void Function(Canvas) draw) async {
      final w = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        final rec = PictureRecorder(); final canvas = Canvas(rec, Rect.fromLTWH(0, 0, 1600, 1200));
        draw(canvas);
        final img = await rec.endRecording().toImage(1600, 1200); img.dispose();
      }
      return w.elapsedMicroseconds ~/ 20;
    }
    final old = await time((canvas) { canvas.save(); canvas.clipPath(outline); canvas.clipPath(screenReceiver); canvas.drawCircle(apex, radius, paint); canvas.restore(); });
    final now = await time((canvas) { canvas.save(); canvas.clipPath(screenReceiver); canvas.drawPath(outline, paint); canvas.restore(); });
    print('software raster per frame: two clips + circle ${old} us, one clip + filled path ${now} us');
  });
}
