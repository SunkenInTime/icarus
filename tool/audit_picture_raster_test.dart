import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'audit_picture_raster.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('integer pixel copy equals full picture crop including clip edges',
      () async {
    for (final scale in [2.0, 8.0]) {
      final picture = recordAuditPicture(scale, (canvas) {
        canvas.drawColor(const ui.Color(0xff101014), ui.BlendMode.src);
        canvas.saveLayer(const ui.Rect.fromLTWH(0, 0, 80, 70), ui.Paint());
        canvas.clipPath(ui.Path()
          ..moveTo(2.37, 4.19)
          ..lineTo(75.11, 10.27)
          ..lineTo(68.83, 67.29)
          ..lineTo(8.43, 59.71)
          ..close());
        canvas.drawCircle(const ui.Offset(38.43, 29.71), 35.2,
            ui.Paint()..color = const ui.Color(0x8800dfba));
        canvas.drawLine(
            const ui.Offset(3.1, 7.9),
            const ui.Offset(74.8, 65.4),
            ui.Paint()
              ..color = const ui.Color(0xffb27c40)
              ..strokeWidth = .9);
        canvas.restore();
      });
      final width = (80 * scale).toInt(), height = (70 * scale).toInt();
      final full = await picture.toImage(width, height);
      try {
        for (final rect in [
          const ui.Rect.fromLTWH(17.23, 14.81, 25.72, 26.13),
          const ui.Rect.fromLTWH(-3.37, 3.17, 23.9, 24.6),
          const ui.Rect.fromLTWH(62.39, 52.01, 24.74, 21.42),
        ]) {
          final pixels = auditPixelBounds(rect, scale, width, height);
          final crop = await copyAuditImagePixels(full, pixels);
          try {
            expect(await auditCropDifferences(full, crop, pixels), 0,
                reason: 'Scale $scale, crop $pixels');
          } finally {
            crop.dispose();
          }
        }
      } finally {
        full.dispose();
        picture.dispose();
      }
    }
  });
}
