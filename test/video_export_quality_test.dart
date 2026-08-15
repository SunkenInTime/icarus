import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/video_export/video_export_quality.dart';

void main() {
  group('VideoExportQuality', () {
    test('uses 30 fps for Social and 60 fps for Max', () {
      expect(VideoExportQuality.social.fps, 30);
      expect(VideoExportQuality.max.fps, 60);
    });
  });

  group('SocialVideoExportPolicy', () {
    test('derives the 22-second bitrate from the working file-size target', () {
      expect(
        SocialVideoExportPolicy.initialVideoBitrate(22),
        3463028,
      );
    });

    test('caps short exports at the Max preset bitrate', () {
      expect(
        SocialVideoExportPolicy.initialVideoBitrate(1),
        SocialVideoExportPolicy.maxVideoBitrate,
      );
    });

    test('rejects durations that fall below the readable bitrate floor', () {
      expect(SocialVideoExportPolicy.initialVideoBitrate(1000), isNull);
    });

    test('scales an oversized encode below the retry target', () {
      final retry = SocialVideoExportPolicy.retryVideoBitrate(
        previousBitrate: 750000,
        actualBytes: 11 * 1024 * 1024,
      );

      expect(retry, 621818);
    });

    test('refuses a retry below the readable bitrate floor', () {
      final retry = SocialVideoExportPolicy.retryVideoBitrate(
        previousBitrate: 250000,
        actualBytes: 20 * 1024 * 1024,
      );

      expect(retry, isNull);
    });

    test('rejects invalid duration and size inputs', () {
      expect(
        () => SocialVideoExportPolicy.initialVideoBitrate(0),
        throwsArgumentError,
      );
      expect(
        () => SocialVideoExportPolicy.retryVideoBitrate(
          previousBitrate: 0,
          actualBytes: 1,
        ),
        throwsArgumentError,
      );
      expect(
        () => SocialVideoExportPolicy.retryVideoBitrate(
          previousBitrate: 1,
          actualBytes: 0,
        ),
        throwsArgumentError,
      );
    });
  });
}
