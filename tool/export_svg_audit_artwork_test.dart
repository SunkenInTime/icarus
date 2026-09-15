// Actual SVG artwork for source-section audit overlays. No world queries/library.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('export actual map artwork at four pixels per SVG unit', () async {
    final out = Directory(
        'E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision/svg-artwork-4x')
      ..createSync(recursive: true);
    for (final map in MapValue.values) {
      final source =
          await File('assets/maps/${map.name}_map.svg').readAsString();
      final artwork = await vg.loadPicture(SvgStringLoader(source), null);
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
        ..scale(4)
        ..drawColor(const ui.Color(0xff101014), ui.BlendMode.src)
        ..drawPicture(artwork.picture);
      final picture = recorder.endRecording();
      final image = await picture.toImage(
          (artwork.size.width * 4).ceil(), (artwork.size.height * 4).ceil());
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${out.path}/${map.name}.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
        picture.dispose();
        artwork.picture.dispose();
      }
    }
  });
}
