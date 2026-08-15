import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/video_export/ffmpeg_video_encoder.dart';
import 'package:icarus/services/video_export/video_export_quality.dart';

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

  group('videoEncodeAttemptProgress', () {
    test('keeps a size-targeted retry monotonic', () {
      final callbacks = <double>[
        videoEncodeAttemptProgress(
          attemptIndex: 0,
          attemptCount: 2,
          attemptFraction: 0,
        ),
        videoEncodeAttemptProgress(
          attemptIndex: 0,
          attemptCount: 2,
          attemptFraction: 1,
        ),
        videoEncodeAttemptProgress(
          attemptIndex: 1,
          attemptCount: 2,
          attemptFraction: 0,
        ),
        videoEncodeAttemptProgress(
          attemptIndex: 1,
          attemptCount: 2,
          attemptFraction: 1,
        ),
      ];

      expect(callbacks, orderedEquals([0, 0.5, 0.5, 1]));
      for (var index = 1; index < callbacks.length; index++) {
        expect(callbacks[index], greaterThanOrEqualTo(callbacks[index - 1]));
      }
    });

    test('clamps progress reported outside the expected duration', () {
      expect(
        videoEncodeAttemptProgress(
          attemptIndex: 0,
          attemptCount: 2,
          attemptFraction: -0.5,
        ),
        0,
      );
      expect(
        videoEncodeAttemptProgress(
          attemptIndex: 1,
          attemptCount: 2,
          attemptFraction: 1.5,
        ),
        1,
      );
    });
  });

  group('videoExportFilter', () {
    test('keeps ordinary Potato exports at 1080p', () {
      expect(
        videoExportFilter(
          quality: VideoExportQuality.potato,
          totalSeconds: 22,
        ),
        'fps=30,format=yuv420p',
      );
    });

    test('downscales floor-bitrate Potato exports to 720p once', () {
      expect(
        videoExportFilter(
          quality: VideoExportQuality.potato,
          totalSeconds: 248,
        ),
        'fps=30,scale=1280:720:flags=lanczos,format=yuv420p',
      );
    });

    test('never downscales Social or Max', () {
      expect(
        videoExportFilter(
          quality: VideoExportQuality.social,
          totalSeconds: 1000,
        ),
        'fps=30,format=yuv420p',
      );
      expect(
        videoExportFilter(
          quality: VideoExportQuality.max,
          totalSeconds: 1000,
        ),
        'fps=60,format=yuv420p',
      );
    });
  });
}
