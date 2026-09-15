// Audit-only raster crops preserve the full picture's physical pixel phase.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

ui.Picture recordAuditPicture(double scale, void Function(ui.Canvas) paint) {
  final recorder = ui.PictureRecorder();
  paint(ui.Canvas(recorder)..scale(scale));
  return recorder.endRecording();
}

ui.Rect auditPixelBounds(ui.Rect svg, double scale, int width, int height) {
  final bounds = ui.Rect.fromLTRB(
      (svg.left * scale).floorToDouble(),
      (svg.top * scale).floorToDouble(),
      (svg.right * scale).ceilToDouble(),
      (svg.bottom * scale).ceilToDouble());
  final clipped = bounds
      .intersect(ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
  if (clipped.isEmpty) throw StateError('Audit viewport is outside the image.');
  return clipped;
}

Future<ui.Image> rasterAuditPicture(ui.Picture picture, ui.Rect pixels) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)
    ..translate(-pixels.left, -pixels.top)
    ..drawPicture(picture);
  // Keep the canvas alive through endRecording; no new paint or scale is used.
  assert(canvas.getSaveCount() == 1);
  final viewport = recorder.endRecording();
  try {
    return await viewport.toImage(pixels.width.toInt(), pixels.height.toInt());
  } finally {
    viewport.dispose();
  }
}

// Integer image copies retain the already-rasterized pixels. Direct picture
// translation is diagnostic only: clipping can change antialiasing values.
Future<ui.Image> copyAuditImagePixels(ui.Image full, ui.Rect pixels) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
      full,
      pixels,
      ui.Rect.fromLTWH(0, 0, pixels.width, pixels.height),
      ui.Paint()
        ..filterQuality = ui.FilterQuality.none
        ..isAntiAlias = false
        ..blendMode = ui.BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(pixels.width.toInt(), pixels.height.toInt());
  } finally {
    picture.dispose();
  }
}

Future<void> writeAuditPng(String path, ui.Image image) async {
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  await File(path).writeAsBytes(bytes!.buffer.asUint8List());
}

Future<int> auditCropDifferences(
    ui.Image full, ui.Image crop, ui.Rect pixels) async {
  final a = (await full.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final b = (await crop.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final Uint8List source =
      a.buffer.asUint8List(a.offsetInBytes, a.lengthInBytes);
  final Uint8List target =
      b.buffer.asUint8List(b.offsetInBytes, b.lengthInBytes);
  var differences = 0;
  for (var y = 0; y < crop.height; y++) {
    for (var x = 0; x < crop.width; x++) {
      final si =
          ((y + pixels.top.toInt()) * full.width + x + pixels.left.toInt()) * 4;
      final ti = (y * crop.width + x) * 4;
      for (var channel = 0; channel < 4; channel++) {
        if (source[si + channel] != target[ti + channel]) differences++;
      }
    }
  }
  return differences;
}
