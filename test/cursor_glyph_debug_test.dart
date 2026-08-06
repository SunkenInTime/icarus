// Scratch diagnostic — renders cursor glyphs the way the vendored
// custom_mouse_cursor plugin does and writes zoomed PNGs to /tmp for visual
// inspection. Not meant to be committed.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/custom_icons.dart';

Future<ui.Image> rasterizeGlyph(IconData icon,
    {required double size, Color color = Colors.white}) async {
  // Mirrors the vendored plugin's supersampled rasterizer.
  const double superSample = 4.0;
  final renderSize = size * superSample;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final textPainter = TextPainter(
    text: TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        inherit: false,
        color: color,
        fontSize: renderSize,
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
      ),
    ),
    textDirection: TextDirection.ltr,
  );
  textPainter.layout();
  textPainter.paint(canvas, Offset.zero);
  final large = recorder.endRecording().toImageSync(
        renderSize.ceil(),
        renderSize.ceil(),
      );
  final r2 = ui.PictureRecorder();
  final c2 = Canvas(r2);
  c2.drawImageRect(
    large,
    Rect.fromLTWH(0, 0, large.width.toDouble(), large.height.toDouble()),
    Rect.fromLTWH(0, 0, size, size),
    Paint()..filterQuality = FilterQuality.high,
  );
  return r2.endRecording().toImageSync(size.ceil(), size.ceil());
}


Future<ui.Image> rasterizeGlyphDirect(IconData icon,
    {required double size, Color color = Colors.white}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final textPainter = TextPainter(
    text: TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        inherit: false,
        color: color,
        fontSize: size,
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
      ),
    ),
    textDirection: TextDirection.ltr,
  );
  textPainter.layout();
  textPainter.paint(canvas, Offset.zero);
  return recorder.endRecording().toImageSync(size.ceil(), size.ceil());
}

Future<void> savePng(ui.Image image, String path, {int zoom = 1}) async {
  ui.Image toSave = image;
  if (zoom > 1) {
    final r = ui.PictureRecorder();
    final c = Canvas(r);
    // dark checker-ish background so white glyphs are visible
    c.drawRect(
        Rect.fromLTWH(0, 0, (image.width * zoom).toDouble(),
            (image.height * zoom).toDouble()),
        Paint()..color = const Color(0xFF223344));
    c.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, (image.width * zoom).toDouble(),
          (image.height * zoom).toDouble()),
      Paint()..filterQuality = FilterQuality.none, // pixel-accurate zoom
    );
    toSave = r
        .endRecording()
        .toImageSync(image.width * zoom, image.height * zoom);
  }
  final bytes = await toSave.toByteData(format: ui.ImageByteFormat.png);
  File(path).writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  testWidgets('render cursor glyphs for inspection', (tester) async {
    await tester.runAsync(() async {
      // Load the real fonts (tests default to the Ahem placeholder font).
      final customLoader = FontLoader('CustomIcons');
      customLoader.addFont(
        File('assets/fonts/CustomIcons.ttf')
            .readAsBytes()
            .then((b) => ByteData.view(Uint8List.fromList(b).buffer)),
      );
      await customLoader.load();

      final materialLoader = FontLoader('MaterialIcons');
      materialLoader.addFont(
        File('/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
            .readAsBytes()
            .then((b) => ByteData.view(Uint8List.fromList(b).buffer)),
      );
      await materialLoader.load();

      Directory('/tmp/cursor_debug').createSync(recursive: true);

      // drawcursor at the sizes the app actually uses:
      // 12 logical (1x screens) and 24 (what a 2x Retina screen gets).
      for (final size in [12.0, 24.0, 48.0]) {
        final img = await rasterizeGlyph(CustomIcons.drawcursor, size: size);
        await savePng(img, '/tmp/cursor_debug/drawcursor_${size.toInt()}.png',
            zoom: (192 / size).round());
      }
      // Material rotation icon at its app sizes: 24 (1x) and 48 (2x).
      for (final size in [24.0, 48.0]) {
        final img =
            await rasterizeGlyph(Icons.rotate_right_rounded, size: size);
        await savePng(img, '/tmp/cursor_debug/material_${size.toInt()}.png',
            zoom: (192 / size).round());
      }
      // Pixel-snapped variant fonts built by fontTools.
      for (final variant in ['a', 'b', 'c']) {
        final loader = FontLoader('Variant_$variant');
        loader.addFont(
          File('/tmp/cursor_debug/variant_$variant.ttf')
              .readAsBytes()
              .then((b) => ByteData.view(Uint8List.fromList(b).buffer)),
        );
        await loader.load();
        // ignore: non_const_argument_for_const_parameter
        final icon = IconData(0xe80e, fontFamily: 'Variant_$variant');
        for (final size in [12.0, 24.0]) {
          final img = await rasterizeGlyph(icon, size: size);
          await savePng(img,
              '/tmp/cursor_debug/variant_${variant}_${size.toInt()}.png',
              zoom: (192 / size).round());
        }
      }
      // A/B: direct single-pass rendering vs supersampled.
      for (final size in [12.0, 24.0]) {
        final img =
            await rasterizeGlyphDirect(CustomIcons.drawcursor, size: size);
        await savePng(
            img, '/tmp/cursor_debug/drawcursor_direct_${size.toInt()}.png',
            zoom: (192 / size).round());
      }
    });
  });
}
