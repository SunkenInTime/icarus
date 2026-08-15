import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/video_export/video_export_quality.dart';
import 'package:icarus/widgets/dialogs/export_video_dialog.dart';

void main() {
  group('videoExportQualityDescription', () {
    test('explains all three outcomes without encoder vocabulary', () {
      expect(
        videoExportQualityDescription(
          VideoExportQuality.potato,
          durationSeconds: 22,
        ),
        '1080p · 30 fps · Aims for 10 MB. Tiny file, full strat.',
      );
      expect(
        videoExportQualityDescription(
          VideoExportQuality.social,
          durationSeconds: 22,
        ),
        '1080p · 30 fps · Aims for 20 MB, optimized for sharing.',
      );
      expect(
        videoExportQualityDescription(
          VideoExportQuality.max,
          durationSeconds: 22,
        ),
        '1080p · 60 fps · Highest quality, larger file.',
      );
    });

    test('discloses the adaptive 720p output for very long exports', () {
      expect(
        videoExportQualityDescription(
          VideoExportQuality.potato,
          durationSeconds: 248,
        ),
        '720p · 30 fps · Aims for 10 MB. Tiny file, full strat.',
      );
    });

    test('defaults Potato copy to 1080p before pages are selected', () {
      expect(
        videoExportQualityDescription(
          VideoExportQuality.potato,
          durationSeconds: null,
        ),
        '1080p · 30 fps · Aims for 10 MB. Tiny file, full strat.',
      );
    });
  });
}
