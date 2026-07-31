import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:path/path.dart' as p;

class VideoExportCancelled implements Exception {}

class VideoExportException implements Exception {
  VideoExportException(this.message);
  final String message;

  @override
  String toString() => 'VideoExportException: $message';
}

/// Encodes a rendered frame sequence into an .mp4 by invoking a bundled (or
/// PATH-installed) ffmpeg binary as a child process (ADR 0001).
class FfmpegVideoEncoder {
  Process? _process;
  bool _cancelled = false;

  static final RegExp _timePattern =
      RegExp(r'time=(\d+):(\d{2}):(\d{2})\.(\d+)');

  /// The packaged binary ships next to the executable (ADR 0004); a PATH
  /// install is the local-development fallback on non-Windows platforms.
  static Future<String?> resolveBinary() async {
    if (Platform.isWindows) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final candidates = [
        p.join(exeDir, 'ffmpeg', 'ffmpeg.exe'),
        p.join(exeDir, 'ffmpeg.exe'),
      ];
      for (final candidate in candidates) {
        if (File(candidate).existsSync()) return candidate;
      }
      // No PATH fallback on Windows: `where` resolves the working directory
      // first, so a planted ffmpeg.exe could be launched. Stage the bundled
      // binary instead (scripts/fetch_ffmpeg.ps1).
      return null;
    }
    try {
      final probe = await Process.run('which', ['ffmpeg']);
      if (probe.exitCode == 0) {
        final line = (probe.stdout as String)
            .split(RegExp(r'\r?\n'))
            .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
        if (line.trim().isNotEmpty) return line.trim();
      }
    } on Object {
      // No ffmpeg on PATH; caller surfaces the error to the user.
    }
    return null;
  }

  void cancel() {
    _cancelled = true;
    _process?.kill();
  }

  /// Encodes the frames listed in [concatListFileName] (an ffconcat file with
  /// per-frame durations, relative to [workingDirectory]) into [outputPath].
  ///
  /// H.264 comes from the OS encoder (`h264_mf` via Media Foundation on
  /// Windows, `libx264` from a user-installed ffmpeg elsewhere); `mpeg4` is
  /// the fallback when the preferred encoder is unavailable on this machine.
  Future<void> encode({
    required String binary,
    required String workingDirectory,
    required String concatListFileName,
    required String outputPath,
    required double totalSeconds,
    void Function(double fraction)? onProgress,
  }) async {
    final baseArgs = [
      '-y',
      '-f', 'concat',
      '-safe', '0',
      '-i', concatListFileName,
      '-vf', 'fps=60,format=yuv420p',
      '-movflags', '+faststart',
    ];
    final codecAttempts = Platform.isWindows
        ? [
            ['-c:v', 'h264_mf', '-b:v', '8M'],
            ['-c:v', 'mpeg4', '-q:v', '3'],
          ]
        : [
            ['-c:v', 'libx264', '-crf', '20', '-preset', 'medium'],
            ['-c:v', 'mpeg4', '-q:v', '3'],
          ];

    // `-y` truncates the user-chosen path immediately, so a failed or
    // cancelled encode must not leave a broken .mp4 behind.
    Future<void> removePartialOutput() async {
      try {
        final output = File(outputPath);
        if (await output.exists()) await output.delete();
      } on Object {
        // Best effort only.
      }
    }

    var lastLog = '';
    for (final codec in codecAttempts) {
      if (_cancelled) {
        await removePartialOutput();
        throw VideoExportCancelled();
      }
      final args = [...baseArgs, ...codec, outputPath];
      final stderrBuffer = StringBuffer();
      final process = await Process.start(
        binary,
        args,
        workingDirectory: workingDirectory,
      );
      _process = process;
      unawaited(process.stdout.drain<void>());
      final stderrDone = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) {
        stderrBuffer.writeln(line);
        final match = _timePattern.firstMatch(line);
        if (match != null && totalSeconds > 0) {
          final seconds = int.parse(match.group(1)!) * 3600 +
              int.parse(match.group(2)!) * 60 +
              int.parse(match.group(3)!) +
              double.parse('0.${match.group(4)!}');
          onProgress?.call((seconds / totalSeconds).clamp(0.0, 1.0));
        }
      });
      final exitCode = await process.exitCode;
      await stderrDone;
      _process = null;
      if (_cancelled) {
        await removePartialOutput();
        throw VideoExportCancelled();
      }
      if (exitCode == 0) {
        onProgress?.call(1.0);
        return;
      }
      lastLog = stderrBuffer.toString();
      log('ffmpeg (${codec.join(' ')}) exited with $exitCode');
    }
    await removePartialOutput();
    final tail = lastLog.split('\n').where((l) => l.trim().isNotEmpty).toList();
    throw VideoExportException(
      'ffmpeg failed: ${tail.isEmpty ? 'unknown error' : tail.last}',
    );
  }
}
