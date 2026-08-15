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

  group('videoEncodeAttemptProgress', () {
    test('keeps a Social size retry monotonic', () {
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
}
