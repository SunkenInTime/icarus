enum VideoExportQuality { social, max }

extension VideoExportQualitySettings on VideoExportQuality {
  int get fps => switch (this) {
        VideoExportQuality.social => 30,
        VideoExportQuality.max => 60,
      };
}

/// File-size policy for the Social video-export preset.
///
/// Attachment limits vary by Discord account and server and are changing over
/// time. Social aims for 20 MiB without turning that external limit into an
/// export failure: long or unusually complex videos still save successfully.
abstract final class SocialVideoExportPolicy {
  static const int targetFileSizeBytes = 20 * 1024 * 1024;
  static const int workingTargetBytes = 19398656; // 18.5 MiB.
  static const int retryTargetBytes = 19922944; // 19 MiB.
  static const int muxOverheadBitsPerSecond = 64000;
  static const int minVideoBitrate = 250000;
  static const int maxVideoBitrate = 8000000;

  /// Keeps very long exports at the readable floor rather than rejecting them.
  static int initialVideoBitrate(double durationSeconds) {
    if (!durationSeconds.isFinite || durationSeconds <= 0) {
      throw ArgumentError.value(
        durationSeconds,
        'durationSeconds',
        'must be finite and greater than zero',
      );
    }

    final available = (workingTargetBytes * 8 / durationSeconds).floor() -
        muxOverheadBitsPerSecond;
    return available.clamp(minVideoBitrate, maxVideoBitrate);
  }

  /// Scales a bitrate after an oversized encode. Returns null when the current
  /// bitrate is already the lowest useful attempt.
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
    final candidate = scaled.clamp(minVideoBitrate, maxVideoBitrate);
    return candidate < previousBitrate ? candidate : null;
  }
}
