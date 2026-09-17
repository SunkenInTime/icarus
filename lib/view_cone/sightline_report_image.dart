import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

/// A crop of the model around the cone's origin, drawn off the widget tree so
/// a report never touches the canvas the user is working on.
///
/// The crop answers the question a screenshot cannot: which walls the reported
/// eye is standing above, and which ones it is standing below.
Future<Uint8List?> renderSightlineReportCrop({
  required SvgHeightVisibility model,
  required ui.Offset origin,
  required ui.Path? visibility,
  required double? eyeElevationMeters,
  required String label,
  double extentSvg = 240,
  double scale = 4,
}) async {
  final crop =
      ui.Rect.fromCenter(center: origin, width: extentSvg, height: extentSvg);
  final pixels = (extentSvg * scale).round();
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(
      recorder, ui.Rect.fromLTWH(0, 0, pixels.toDouble(), pixels.toDouble()));
  canvas.drawPaint(Paint()..color = Settings.tacticalVioletTheme.background);
  canvas.save();
  canvas.scale(scale);
  canvas.translate(-crop.left, -crop.top);

  final receiverPaint = Paint()..color = Settings.tacticalVioletTheme.card;
  for (final receiver in model.receivers) {
    canvas.drawPath(_path(receiver.rings, receiver.evenOdd), receiverPaint);
  }

  final blocking = Paint()..color = Settings.sightlineReportBlockingWall;
  final clear = Paint()..color = Settings.sightlineReportClearWall;
  for (final wall in model.walls) {
    if (!wall.bounds.overlaps(crop)) continue;
    final blocks =
        eyeElevationMeters == null || wall.blocks(eyeElevationMeters);
    canvas.drawPath(_path(wall.rings, wall.evenOdd), blocks ? blocking : clear);
  }

  if (visibility != null) {
    canvas.drawPath(visibility,
        Paint()..color = Settings.sightlineReportCone.withValues(alpha: 0.45));
  }
  canvas.drawCircle(origin, 1.5, Paint()..color = const Color(0xffffffff));
  canvas.restore();

  final paragraph = (ui.ParagraphBuilder(ui.ParagraphStyle(
    fontSize: 14,
    textDirection: TextDirection.ltr,
  ))
        ..pushStyle(ui.TextStyle(color: const Color(0xffffffff)))
        ..addText(label))
      .build()
    ..layout(ui.ParagraphConstraints(width: pixels - 16));
  canvas.drawRect(
      ui.Rect.fromLTWH(0, pixels - paragraph.height - 12, pixels.toDouble(),
          paragraph.height + 12),
      Paint()..color = const Color(0xcc000000));
  canvas.drawParagraph(paragraph, ui.Offset(8, pixels - paragraph.height - 6));

  final picture = recorder.endRecording();
  final image = await picture.toImage(pixels, pixels);
  picture.dispose();
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

ui.Path _path(List<List<ui.Offset>> rings, bool evenOdd) {
  final path = ui.Path()
    ..fillType = evenOdd ? ui.PathFillType.evenOdd : ui.PathFillType.nonZero;
  for (final ring in rings) {
    if (ring.isEmpty) continue;
    path.addPolygon(ring, true);
  }
  return path;
}
