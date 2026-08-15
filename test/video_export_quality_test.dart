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
        6990056,
      );
    });

    test('caps short exports at the Max preset bitrate', () {
      expect(
        SocialVideoExportPolicy.initialVideoBitrate(1),
        SocialVideoExportPolicy.maxVideoBitrate,
      );
    });

    test('keeps long exports at the readable bitrate floor', () {
      expect(
        SocialVideoExportPolicy.initialVideoBitrate(1000),
        SocialVideoExportPolicy.minVideoBitrate,
      );
    });

    test('scales an oversized encode below the retry target', () {
      final retry = SocialVideoExportPolicy.retryVideoBitrate(
        previousBitrate: 1500000,
        actualBytes: 22 * 1024 * 1024,
      );

      expect(retry, 1243636);
    });

    test('clamps a useful retry at the readable bitrate floor', () {
      final retry = SocialVideoExportPolicy.retryVideoBitrate(
        previousBitrate: 500000,
        actualBytes: 40 * 1024 * 1024,
      );

      expect(retry, SocialVideoExportPolicy.minVideoBitrate);
    });

    test('skips a retry when already at the readable bitrate floor', () {
      final retry = SocialVideoExportPolicy.retryVideoBitrate(
        previousBitrate: SocialVideoExportPolicy.minVideoBitrate,
        actualBytes: 40 * 1024 * 1024,
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
