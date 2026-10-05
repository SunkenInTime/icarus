import 'dart:typed_data';

/// Where [VideoExporter] sends the frames it renders: an encoder that turns
/// them into an .mp4. Desktop pipes them to the bundled ffmpeg
/// (`FfmpegVideoSink`); the browser encodes them with WebCodecs
/// (`createBrowserVideoSink`).
abstract interface class VideoFrameSink {
  /// Called once, before the first frame. Every frame is [width] x [height];
  /// the video runs [totalSeconds] over [totalFrames] frames.
  Future<void> start({
    required int width,
    required int height,
    required int totalFrames,
    required double totalSeconds,
  });

  /// One rendered frame, top-to-bottom RGBA, shown for [durationSeconds].
  Future<void> addFrame(Uint8List rgba, double durationSeconds);

  /// Encodes every frame added. Returns the finished video when this sink
  /// keeps it in memory (the browser), or null once it is written to its
  /// file (desktop). [onProgress] reports 0 to 1.
  Future<Uint8List?> finish({void Function(double fraction)? onProgress});

  /// Stops the encode in flight; [addFrame] and [finish] then throw
  /// `VideoExportCancelled`.
  void cancel();

  /// Releases everything the sink holds. Safe after [finish], after
  /// [cancel], and after a failure.
  Future<void> close();
}
