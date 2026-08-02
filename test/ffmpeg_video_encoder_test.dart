import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/video_export/ffmpeg_video_encoder.dart';

void main() {
  group('ensureMp4Extension', () {
    test('appends the extension when the save dialog omits it', () {
      expect(
          ensureMp4Extension(r'C:\Videos\strategy'), r'C:\Videos\strategy.mp4');
    });

    test('preserves an existing extension regardless of case', () {
      expect(ensureMp4Extension(r'C:\Videos\strategy.MP4'),
          r'C:\Videos\strategy.MP4');
    });
  });
}
