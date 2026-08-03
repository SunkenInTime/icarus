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
      _finished = true;
      process.kill();
      final exitCode = await _awaitExit(process);
      await _drainOutput();
      _process = null;
      throw VideoExportException(
        'Frame preparation failed (ffmpeg exit ${exitCode ?? 'unknown'}): '
        '${_lastError()}',
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
    final exitCode = await _awaitExit(process);
    await _drainOutput();
    _process = null;

    if (_cancelled) throw VideoExportCancelled();
    if (exitCode != 0) {
      throw VideoExportException(
        'Frame preparation failed (ffmpeg exit ${exitCode ?? 'unknown'}): '
        '${_lastError()}',
      );
    }
  }

  /// Waits for [process] to exit, escalating to SIGKILL when it stalls, so a
  /// hung ffmpeg can never freeze the export with no error and no progress.
  /// Returns null when the process refused to die within the grace period.
  Future<int?> _awaitExit(Process process) async {
    try {
      return await process.exitCode.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      try {
        return await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        return null;
      }
    }
  }

  Future<void> _drainOutput() async {
    try {
      await Future.wait<void>([
        if (_stdoutDone != null) _stdoutDone!,
        if (_stderrDone != null) _stderrDone!,
      ]).timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // The pipes outlive a process that refused to die; stop waiting.
    }
  }

  String _lastError() {
    final lines = _stderr
        .toString()
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    return lines.isEmpty ? 'unknown error' : lines.last;
  }

  /// Stops accepting frames and terminates ffmpeg. Completes once the process
  /// has exited (or the grace period elapsed), so callers can safely delete
  /// the frame directory it was writing into.
  Future<void> cancel() async {
    _cancelled = true;
    final process = _process;
    if (process == null) return;
    process.kill();
    await _awaitExit(process);
    await _drainOutput();
    _process = null;
  }
}
