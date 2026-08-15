import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/video_export/video_export_quality.dart';

void main() {
  group('VideoExportQuality', () {
    test('uses 30 fps for Potato and Social and 60 fps for Max', () {
      expect(VideoExportQuality.potato.fps, 30);
      expect(VideoExportQuality.social.fps, 30);
      expect(VideoExportQuality.max.fps, 60);
    });

    test('only file-size presets expose a size policy', () {
      expect(
        VideoExportQuality.potato.sizePolicy,
        same(VideoExportSizePolicies.potato),
      );
      expect(
        VideoExportQuality.social.sizePolicy,
        same(VideoExportSizePolicies.social),
      );
      expect(VideoExportQuality.max.sizePolicy, isNull);
    });

    test('Potato only drops to 720p at the readable bitrate floor', () {
      expect(VideoExportQuality.potato.outputHeightForDuration(22), 1080);
      expect(VideoExportQuality.potato.outputHeightForDuration(247), 1080);
      expect(VideoExportQuality.potato.outputHeightForDuration(248), 720);
      expect(VideoExportQuality.potato.outputHeightForDuration(1000), 720);
    });

    test('Social and Max retain 1080p for every duration', () {
      expect(VideoExportQuality.social.outputHeightForDuration(1000), 1080);
      expect(VideoExportQuality.max.outputHeightForDuration(1000), 1080);
    });
  });

  group('VideoExportSizePolicies', () {
    test('use 10 MiB and 20 MiB best-effort targets', () {
      expect(
        VideoExportSizePolicies.potato.targetFileSizeBytes,
        10 * 1024 * 1024,
      );
      expect(
        VideoExportSizePolicies.social.targetFileSizeBytes,
        20 * 1024 * 1024,
      );
    });

    test('derive 22-second bitrates from each working target', () {
      expect(
        VideoExportSizePolicies.potato.initialVideoBitrate(22),
        3463028,
      );
      expect(
        VideoExportSizePolicies.social.initialVideoBitrate(22),
        6990056,
      );
    });

    test('caps short exports at the Max preset bitrate', () {
      expect(
        VideoExportSizePolicies.potato.initialVideoBitrate(1),
        VideoExportSizePolicy.maxVideoBitrate,
      );
      expect(
        VideoExportSizePolicies.social.initialVideoBitrate(1),
        VideoExportSizePolicy.maxVideoBitrate,
      );
    });

    test('keeps long exports at the readable bitrate floor', () {
      expect(
        VideoExportSizePolicies.potato.initialVideoBitrate(1000),
        VideoExportSizePolicy.minVideoBitrate,
      );
      expect(
        VideoExportSizePolicies.social.initialVideoBitrate(1000),
        VideoExportSizePolicy.minVideoBitrate,
      );
    });

    test('scales oversized encodes below each retry target', () {
      expect(
        VideoExportSizePolicies.potato.retryVideoBitrate(
          previousBitrate: 1500000,
          actualBytes: 11 * 1024 * 1024,
        ),
        1243636,
      );
      expect(
        VideoExportSizePolicies.social.retryVideoBitrate(
          previousBitrate: 1500000,
          actualBytes: 22 * 1024 * 1024,
        ),
        1243636,
      );
    });

    test('clamps a useful retry at the readable bitrate floor', () {
      final retry = VideoExportSizePolicies.potato.retryVideoBitrate(
        previousBitrate: 500000,
        actualBytes: 40 * 1024 * 1024,
      );

      expect(retry, VideoExportSizePolicy.minVideoBitrate);
    });

    test('skips a retry when already at the readable bitrate floor', () {
      final retry = VideoExportSizePolicies.potato.retryVideoBitrate(
        previousBitrate: VideoExportSizePolicy.minVideoBitrate,
        actualBytes: 40 * 1024 * 1024,
      );

      expect(retry, isNull);
    });

    test('rejects invalid duration and size inputs', () {
      expect(
        () => VideoExportSizePolicies.potato.initialVideoBitrate(0),
        throwsArgumentError,
      );
      expect(
        () => VideoExportSizePolicies.potato.retryVideoBitrate(
          previousBitrate: 0,
          actualBytes: 1,
        ),
        throwsArgumentError,
      );
      expect(
        () => VideoExportSizePolicies.potato.retryVideoBitrate(
          previousBitrate: 1,
          actualBytes: 0,
        ),
        throwsArgumentError,
      );
    });
  });
}
