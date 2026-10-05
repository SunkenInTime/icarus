import 'dart:typed_data';

import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/services/video_export/video_export_quality.dart';
import 'package:icarus/services/video_export/video_frame_sink.dart';
import 'package:icarus/services/video_export/web_codecs_video_encoder.dart';

/// Whether this browser can encode a [totalSeconds] video at [quality],
/// checked with the exact size and bitrate the export will use, before
/// anything renders.
Future<bool> browserCanEncodeVideo(
  VideoExportQuality quality, {
  required double totalSeconds,
}) {
  final output = _outputFor(quality, totalSeconds);
  return WebCodecsMp4Encoder.isSupported(
    width: output.width,
    height: output.height,
    fps: quality.fps,
    bitrate: output.bitrate,
  );
}

/// The size and bitrate [quality] encodes a [totalSeconds] video at: the
/// desktop presets' (Potato drops to 720p at its bitrate floor; Max has no
/// fixed bitrate).
({int width, int height, int? bitrate}) _outputFor(
  VideoExportQuality quality,
  double totalSeconds,
) {
  const frame = CoordinateSystem.screenShotSize;
  final height = quality.outputHeightForDuration(totalSeconds);
  return (
    width: (frame.width * height / frame.height).round(),
    height: height,
    bitrate: quality.sizePolicy?.initialVideoBitrate(totalSeconds),
  );
}

/// Encodes in the browser with WebCodecs; [VideoFrameSink.finish] returns
/// the finished .mp4 for the caller to download.
VideoFrameSink createBrowserVideoSink(VideoExportQuality quality) =>
    _WebCodecsVideoSink(quality);

/// Sizes and bitrates follow the desktop presets: Potato and Social hold the
/// bitrate their size target allows for the video's length (and Potato
/// drops to 720p at the bitrate floor); Max encodes at a high variable
/// bitrate. The browser encodes as frames arrive, so there is no separate
/// encode pass and no second attempt at a smaller size.
class _WebCodecsVideoSink implements VideoFrameSink {
  _WebCodecsVideoSink(this.quality);

  final VideoExportQuality quality;
  final WebCodecsMp4Encoder _encoder = WebCodecsMp4Encoder();

  @override
  Future<void> start({
    required int width,
    required int height,
    required int totalFrames,
    required double totalSeconds,
  }) {
    final output = _outputFor(quality, totalSeconds);
    return _encoder.start(
      inputWidth: width,
      inputHeight: height,
      outputWidth: output.width,
      outputHeight: output.height,
      fps: quality.fps,
      bitrate: output.bitrate,
    );
  }

  @override
  Future<void> addFrame(Uint8List rgba, double durationSeconds) =>
      _encoder.addFrame(
        rgba,
        duration: Duration(microseconds: (durationSeconds * 1e6).round()),
      );

  @override
  Future<Uint8List?> finish({
    void Function(double fraction)? onProgress,
  }) async {
    final video = await _encoder.finish();
    onProgress?.call(1);
    return video;
  }

  @override
  void cancel() => _encoder.cancel();

  @override
  Future<void> close() async => _encoder.cancel();
}
