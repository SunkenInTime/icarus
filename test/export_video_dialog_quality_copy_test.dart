import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/video_export/video_export_quality.dart';
import 'package:icarus/widgets/dialogs/export_video_dialog.dart';

void main() {
  group('videoExportQualityCaption', () {
    test('states each option\'s distinguishing fact, no encoder vocabulary',
        () {
      expect(videoExportQualityCaption(VideoExportQuality.potato), '~10 MB');
      expect(videoExportQualityCaption(VideoExportQuality.social), '~20 MB');
      expect(
        videoExportQualityCaption(VideoExportQuality.max),
        '60 fps, no size cap',
      );
    });
  });
}
