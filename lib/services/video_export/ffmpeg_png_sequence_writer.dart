import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:icarus/services/video_export/ffmpeg_video_encoder.dart';

/// Streams raw Flutter frames to one FFmpeg process that writes the lossless
/// PNG sequence consumed by [FfmpegVideoEncoder].
///
/// Flutter's PNG conversion is expensive at 1080p. Raw RGBA readback is much
/// faster, and the long-lived native process can encode frames while Flutter
/// prepares the next one without retaining raw frames on disk.
class FfmpegPngSequenceWriter {
  Process? _process;
  Future<void>? _stdoutDone;
  Future<void>? _stderrDone;
  final StringBuffer _stderr = StringBuffer();
  bool _cancelled = false;
  bool _started = false;
  bool _finished = false;
  int? _expectedFrameBytes;

  Future<void> start({
    required String binary,
    required String workingDirectory,
    required int width,
    required int height,
    required int fps,
    required int totalFrames,
  }) async {
    if (_started) {
      throw StateError('The PNG sequence writer has already been started.');
    }
    _started = true;
    _expectedFrameBytes = width * height * 4;

    final process = await Process.start(
      binary,
      [
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-f',
        'rawvideo',
        '-pixel_format',
        'rgba',
        '-video_size',
        '${width}x$height',
        '-framerate',
        '$fps',
        '-i',
        'pipe:0',
        '-frames:v',
        '$totalFrames',
        '-fps_mode',
        'passthrough',
        '-start_number',
        '0',
        'frame_%05d.png',
      ],
      workingDirectory: workingDirectory,
    );
    _process = process;
    _stdoutDone = process.stdout.drain<void>();
    _stderrDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach(_stderr.writeln);
  }

  Future<void> writeFrame(Uint8List rgbaBytes) async {
    final process = _process;
    if (!_started || process == null || _finished) {
      throw StateError('The PNG sequence writer is not accepting frames.');
    }
    if (_cancelled) throw VideoExportCancelled();
    if (rgbaBytes.lengthInBytes != _expectedFrameBytes) {
      throw VideoExportException(
        'Frame preparation received ${rgbaBytes.lengthInBytes} bytes; '
        'expected $_expectedFrameBytes.',
      );
    }

    try {
      process.stdin.add(rgbaBytes);
      await process.stdin.flush();
    } on Object {
      if (_cancelled) throw VideoExportCancelled();
      final exitCode = await process.exitCode;
      await _drainOutput();
      _process = null;
      throw VideoExportException(
        'Frame preparation failed (ffmpeg exit $exitCode): ${_lastError()}',
      );
    }
  }

  Future<void> finish() async {
    final process = _process;
    if (!_started || process == null || _finished) {
      throw StateError('The PNG sequence writer is not running.');
    }
    _finished = true;

    await process.stdin.close();
    final exitCode = await process.exitCode;
    await _drainOutput();
    _process = null;

    if (_cancelled) throw VideoExportCancelled();
    if (exitCode != 0) {
      throw VideoExportException(
        'Frame preparation failed (ffmpeg exit $exitCode): ${_lastError()}',
      );
    }
  }

  Future<void> _drainOutput() async {
    await _stdoutDone;
    await _stderrDone;
  }

  String _lastError() {
    final lines = _stderr
        .toString()
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    return lines.isEmpty ? 'unknown error' : lines.last;
  }

  void cancel() {
    _cancelled = true;
    _process?.kill();
  }
}
