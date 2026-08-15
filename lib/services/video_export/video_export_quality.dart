enum VideoExportQuality { social, max }

extension VideoExportQualitySettings on VideoExportQuality {
  int get fps => switch (this) {
        VideoExportQuality.social => 30,
        VideoExportQuality.max => 60,
      };
}

/// File-size policy for the Social video-export preset.
///
/// Discord documents a 10 MiB default attachment limit. The first encode
/// targets 9.25 MiB, leaving room for MP4 muxing and encoder overhead; the
/// finished file is still measured before it replaces the destination.
abstract final class SocialVideoExportPolicy {
  static const int maxFileSizeBytes = 10 * 1024 * 1024;
  static const int workingTargetBytes = 9699328; // 9.25 MiB.
  static const int retryTargetBytes = 9961472; // 9.50 MiB.
  static const int muxOverheadBitsPerSecond = 64000;
  static const int minVideoBitrate = 250000;
  static const int maxVideoBitrate = 8000000;

  /// Returns null when fitting the duration would require a bitrate below the
  /// readable floor. The caller should ask the user to shorten the export.
  static int? initialVideoBitrate(double durationSeconds) {
    if (!durationSeconds.isFinite || durationSeconds <= 0) {
      throw ArgumentError.value(
        durationSeconds,
        'durationSeconds',
        'must be finite and greater than zero',
      );
    }

    final available = (workingTargetBytes * 8 / durationSeconds).floor() -
        muxOverheadBitsPerSecond;
    if (available < minVideoBitrate) return null;
    return available.clamp(minVideoBitrate, maxVideoBitrate);
  }

  /// Scales a bitrate after an oversized encode. Returns null rather than
  /// crossing the readable floor.
  static int? retryVideoBitrate({
    required int previousBitrate,
    required int actualBytes,
  }) {
    if (previousBitrate <= 0) {
      throw ArgumentError.value(
        previousBitrate,
        'previousBitrate',
        'must be greater than zero',
      );
    }
    if (actualBytes <= 0) {
      throw ArgumentError.value(
        actualBytes,
        'actualBytes',
        'must be greater than zero',
      );
    }

    final scaled =
        (previousBitrate * (retryTargetBytes / actualBytes) * 0.96).floor();
    if (scaled < minVideoBitrate) return null;
    return scaled.clamp(minVideoBitrate, maxVideoBitrate);
  }
}
