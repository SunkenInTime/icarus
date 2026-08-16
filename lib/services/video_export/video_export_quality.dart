enum VideoExportQuality { potato, social, max }

extension VideoExportQualitySettings on VideoExportQuality {
  int get fps => switch (this) {
        VideoExportQuality.potato || VideoExportQuality.social => 30,
        VideoExportQuality.max => 60,
      };

  VideoExportSizePolicy? get sizePolicy => switch (this) {
        VideoExportQuality.potato => VideoExportSizePolicies.potato,
        VideoExportQuality.social => VideoExportSizePolicies.social,
        VideoExportQuality.max => null,
      };

  /// Potato only drops to 720p when its duration-derived bitrate reaches the
  /// readable floor. At every higher tested bitrate, 1080p retained more map
  /// and label detail for the same sharing target.
  int outputHeightForDuration(double durationSeconds) {
    final policy = sizePolicy;
    if (policy == null) return 1080;
    return policy.outputHeightForBitrate(
      policy.initialVideoBitrate(durationSeconds),
    );
  }
}

/// A best-effort file-size policy shared by Potato and Social.
///
/// File size can trigger one lower-bitrate retry, but it never turns a
/// successful encode into a failure.
class VideoExportSizePolicy {
  const VideoExportSizePolicy({
    required this.targetFileSizeBytes,
    required this.workingTargetBytes,
    required this.retryTargetBytes,
    this.outputHeightAtBitrateFloor,
  });

  static const int muxOverheadBitsPerSecond = 64000;
  static const int minVideoBitrate = 250000;
  static const int maxVideoBitrate = 8000000;

  final int targetFileSizeBytes;
  final int workingTargetBytes;
  final int retryTargetBytes;
  final int? outputHeightAtBitrateFloor;

  /// Keeps very long exports at the readable floor rather than rejecting them.
  int initialVideoBitrate(double durationSeconds) {
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
  int? retryVideoBitrate({
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

  int outputHeightForBitrate(int videoBitrate) {
    if (outputHeightAtBitrateFloor != null && videoBitrate <= minVideoBitrate) {
      return outputHeightAtBitrateFloor!;
    }
    return 1080;
  }
}

/// Attachment limits vary by Discord account and server and are changing over
/// time. These presets optimize toward useful sharing targets without making
/// an external limit an Icarus export gate.
abstract final class VideoExportSizePolicies {
  static const potato = VideoExportSizePolicy(
    targetFileSizeBytes: 10 * 1024 * 1024,
    workingTargetBytes: 9699328, // 9.25 MiB.
    retryTargetBytes: 9961472, // 9.5 MiB.
    outputHeightAtBitrateFloor: 720,
  );

  static const social = VideoExportSizePolicy(
    targetFileSizeBytes: 20 * 1024 * 1024,
    workingTargetBytes: 19398656, // 18.5 MiB.
    retryTargetBytes: 19922944, // 19 MiB.
  );
}
