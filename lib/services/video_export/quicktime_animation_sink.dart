import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:icarus/services/video_export/mp4_muxer.dart';
import 'package:icarus/services/video_export/quicktime_animation_encoder.dart';
import 'package:icarus/services/video_export/video_export_errors.dart';
import 'package:icarus/services/video_export/video_frame_sink.dart';

/// Windows' save dialog does not guarantee that the selected extension is
/// appended, even when FilePicker is restricted to .mov files.
String ensureMovExtension(String path) =>
    path.toLowerCase().endsWith('.mov') ? path : '$path.mov';

/// Transparent video, on desktop and in the browser alike: frames become a
/// lossless QuickTime Animation .mov (see [QuickTimeAnimationEncoder]),
/// encoded in Dart as they arrive.
///
/// The video is constant frame rate, as editors expect: each frame repeats at
/// [fps] for its duration. A repeat that changes nothing costs a few bytes,
/// and a keyframe every two seconds keeps seeking quick. The last frame is a
/// keyframe too: Clipchamp ends a QuickTime Animation clip at its last
/// keyframe, and would cut off whatever followed it.
///
/// With an [outputPath] (desktop) the finished file is written there and
/// [finish] returns null; without one (the browser) [finish] returns it.
class QuickTimeAnimationSink implements VideoFrameSink {
  QuickTimeAnimationSink({required this.fps, this.outputPath});

  final int fps;
  final String? outputPath;

  static const _maxKeyFrameIntervalSeconds = 2;

  /// A sample that repeats the previous frame (QuickTimeAnimationEncoder's
  /// unchanged frame), shared rather than re-encoded for every held tick.
  static final _unchanged = Uint8List.fromList([0, 0, 0, 7, 0, 0, 0]);

  QuickTimeAnimationEncoder? _encoder;
  MovAnimationMuxer? _muxer;
  int _framesEncoded = 0;
  int _framesSinceKeyFrame = 0;

  /// How many times [addFrame] will be called, and has been.
  int _framesExpected = 0;
  int _framesAdded = 0;

  /// Sum of every [addFrame] duration, so rounding never accumulates.
  int _plannedMicros = 0;
  bool _cancelled = false;

  @override
  Future<void> start({
    required int width,
    required int height,
    required int totalFrames,
    required double totalSeconds,
  }) async {
    _checkNotCancelled();
    _framesExpected = totalFrames;
    _encoder = QuickTimeAnimationEncoder(width: width, height: height);
    // 1000 ticks a frame keeps every duration an exact integer.
    _muxer = MovAnimationMuxer(
      width: width,
      height: height,
      timescale: fps * 1000,
    );
  }

  @override
  Future<void> addFrame(Uint8List rgba, double durationSeconds) async {
    _checkNotCancelled();
    final encoder = _encoder!;
    final muxer = _muxer!;
    _plannedMicros +=
        (durationSeconds * Duration.microsecondsPerSecond).round();
    final plannedFrames =
        (_plannedMicros * fps / Duration.microsecondsPerSecond).round();
    final repeats = math.max(1, plannedFrames - _framesEncoded);
    final lastFrame = ++_framesAdded == _framesExpected;

    for (var i = 0; i < repeats; i++) {
      final keyFrame = _framesEncoded == 0 ||
          _framesSinceKeyFrame >= _maxKeyFrameIntervalSeconds * fps ||
          (lastFrame && i == repeats - 1);
      final Uint8List sample;
      if (i == 0 || keyFrame) {
        sample = encoder.encode(rgba, keyFrame: keyFrame);
      } else {
        sample = _unchanged;
      }
      muxer.addSample(sample, duration: 1000, isKeyFrame: keyFrame);
      _framesEncoded++;
      _framesSinceKeyFrame = keyFrame ? 1 : _framesSinceKeyFrame + 1;
    }
  }

  @override
  Future<Uint8List?> finish({
    void Function(double fraction)? onProgress,
  }) async {
    _checkNotCancelled();
    final video = _muxer!.finish();
    final path = outputPath;
    if (path == null) {
      onProgress?.call(1);
      return video;
    }
    // Written beside the destination and renamed over it, so a failed write
    // never damages a video already there (as FfmpegVideoEncoder does).
    final partial = File('$path.icarus-partial.mov');
    try {
      await partial.writeAsBytes(video, flush: true);
      await partial.rename(path);
    } on Object catch (error) {
      try {
        if (await partial.exists()) await partial.delete();
      } on Object {
        // Best effort only.
      }
      throw VideoExportException(
        'Could not write the video to the selected location: $error',
      );
    }
    onProgress?.call(1);
    return null;
  }

  @override
  void cancel() => _cancelled = true;

  @override
  Future<void> close() async {
    _encoder = null;
    _muxer = null;
  }

  void _checkNotCancelled() {
    if (_cancelled) throw VideoExportCancelled();
  }
}
