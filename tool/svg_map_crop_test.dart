// Crops the bundled map art around SVG points so a spot in a sightline
// report can be looked at against the drawn map.
//
// Env:
//   ICARUS_CROP_MAP=bind ICARUS_CROP_SIDE=attack
//   ICARUS_CROP_POINTS="238,208;56,143"   (svg x, svg y)
//   ICARUS_CROP_OUT=build/map-crops
// Each point writes <out>/<map>_<side>_<i>.png with the point marked.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('crop map art', () async {
    final env = Platform.environment;
    final map = env['ICARUS_CROP_MAP'] ?? 'bind';
    final side = env['ICARUS_CROP_SIDE'] ?? 'attack';
    final out = Directory(env['ICARUS_CROP_OUT'] ?? 'build/map-crops')
      ..createSync(recursive: true);
    final points = (env['ICARUS_CROP_POINTS'] ?? '238,208')
        .split(';')
        .map((p) => p.split(',').map(double.parse).toList())
        .toList();
    final suffix = side == 'attack' ? '' : '_defense';
    final layers = <PictureInfo>[];
    for (final name in ['${map}_map$suffix.svg', '${map}_call_outs$suffix.svg']) {
      final file = File('assets/maps/$name');
      if (!file.existsSync()) continue;
      layers.add(await vg.loadPicture(SvgStringLoader(file.readAsStringSync()), null));
    }
    const half = 40.0, scale = 8.0;
    for (var i = 0; i < points.length; i++) {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder)
        ..drawRect(const ui.Rect.fromLTWH(0, 0, half * 2 * scale, half * 2 * scale),
            ui.Paint()..color = const ui.Color(0xff202020))
        ..scale(scale)
        ..translate(half - points[i][0], half - points[i][1]);
      for (final layer in layers) {
        canvas.drawPicture(layer.picture);
      }
      canvas.drawCircle(ui.Offset(points[i][0], points[i][1]), 1.5,
          ui.Paint()..color = const ui.Color(0xffff3355));
      final image = await recorder.endRecording().toImage((half * 2 * scale).toInt(), (half * 2 * scale).toInt());
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('${out.path}/${map}_${side}_$i.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    }
    for (final layer in layers) {
      layer.picture.dispose();
    }
  });
}
