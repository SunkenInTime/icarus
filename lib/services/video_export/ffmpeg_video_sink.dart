import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:icarus/services/video_export/ffmpeg_png_sequence_writer.dart';
import 'package:icarus/services/video_export/ffmpeg_video_encoder.dart';
import 'package:icarus/services/video_export/video_export_quality.dart';
import 'package:icarus/services/video_export/video_frame_sink.dart';
import 'package:path/path.dart' as p;

/// Desktop: frames go to one ffmpeg process as a lossless PNG sequence,
/// listed with their durations in an ffconcat playlist, and a second ffmpeg
/// run encodes the playlist into [outputPath].
class FfmpegVideoSink implements VideoFrameSink {
  FfmpegVideoSink({
    required this.binary,
    required this.outputPath,
    required this.quality,
  });

  final String binary;
  final String outputPath;
  final VideoExportQuality quality;

  final FfmpegVideoEncoder _encoder = FfmpegVideoEncoder();
  final List<String> _concatLines = ['ffconcat version 1.0'];
  Directory? _tempDir;
  FfmpegPngSequenceWriter? _frameWriter;
  double _totalSeconds = 0;
  int _frameIndex = 0;
  String? _lastFrameFile;

  @override
  Future<void> start({
    required int width,
    required int height,
    required int totalFrames,
    required double totalSeconds,
  }) async {
    _totalSeconds = totalSeconds;
    final tempDir =
        await Directory.systemTemp.createTemp('icarus_video_export_');
    _tempDir = tempDir;
    final frameWriter = FfmpegPngSequenceWriter();
    _frameWriter = frameWriter;
    await frameWriter.start(
      binary: binary,
      workingDirectory: tempDir.path,
      width: width,
      height: height,
      fps: quality.fps,
      totalFrames: totalFrames,
    );
  }

  @override
  Future<void> addFrame(Uint8List rgba, double durationSeconds) async {
    final fileName = 'frame_${_frameIndex.toString().padLeft(5, '0')}.png';
    await _frameWriter!.writeFrame(rgba);
    _frameIndex++;
    _concatLines
      ..add("file '$fileName'")
      ..add('duration ${durationSeconds.toStringAsFixed(6)}');
    _lastFrameFile = fileName;
  }

  @override
  Future<Uint8List?> finish(
      {void Function(double fraction)? onProgress}) async {
    await _frameWriter!.finish();
    _frameWriter = null;

    // The concat demuxer ignores the duration of the final entry unless the
    // last file is repeated.
    if (_lastFrameFile != null) {
      _concatLines.add("file '$_lastFrameFile'");
    }
    final tempDir = _tempDir!;
    await File(p.join(tempDir.path, 'frames.ffconcat'))
        .writeAsString(_concatLines.join('\n'));

    await _encoder.encode(
      binary: binary,
      workingDirectory: tempDir.path,
      concatListFileName: 'frames.ffconcat',
      outputPath: outputPath,
      totalSeconds: _totalSeconds,
      quality: quality,
      onProgress: onProgress,
    );
    return null;
  }

  @override
  void cancel() {
    // close() awaits the writer's termination; here we only need to
    // interrupt the processes.
    unawaited(_frameWriter?.cancel());
    _encoder.cancel();
  }

  @override
  Future<void> close() async {
    // Wait for ffmpeg to exit before deleting the directory it writes into;
    // on Windows the delete races a still-exiting process otherwise.
    await _frameWriter?.cancel();
    _frameWriter = null;
    try {
      await _tempDir?.delete(recursive: true);
      _tempDir = null;
    } on Object {
      // Leaving orphaned temp frames behind is preferable to masking the
      // original export result.
    }
  }
}
