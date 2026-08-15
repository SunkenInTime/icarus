import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:icarus/services/video_export/video_export_quality.dart';
import 'package:path/path.dart' as p;

class VideoExportCancelled implements Exception {}

class VideoExportException implements Exception {
  VideoExportException(this.message);
  final String message;

  @override
  String toString() => 'VideoExportException: $message';
}

/// Windows' save dialog does not guarantee that the selected extension is
/// appended, even when FilePicker is restricted to MP4 files.
String ensureMp4Extension(String path) =>
    path.toLowerCase().endsWith('.mp4') ? path : '$path.mp4';

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
  /// Windows, `libx264` from a user-installed ffmpeg elsewhere). Max quality
  /// retains the `mpeg4` fallback; Social stays on H.264 so its bitrate-guided
  /// sharing target remains meaningful.
  Future<void> encode({
    required String binary,
    required String workingDirectory,
    required String concatListFileName,
    required String outputPath,
    required double totalSeconds,
    required VideoExportQuality quality,
    void Function(double fraction)? onProgress,
  }) async {
    var socialBitrate = quality == VideoExportQuality.social
        ? SocialVideoExportPolicy.initialVideoBitrate(totalSeconds)
        : null;

    final baseArgs = [
      '-y',
      '-f',
      'concat',
      '-safe',
      '0',
      '-i',
      concatListFileName,
      '-vf',
      'fps=${quality.fps},format=yuv420p',
      // The concat playlist repeats its final still so FFmpeg honors that
      // entry's duration. Some FFmpeg builds inherit the duration on the
      // repeated file and hold the final page twice, so cap the output to the
      // duration planned by VideoExporter.
      '-t',
      totalSeconds.toStringAsFixed(6),
      '-movflags',
      '+faststart',
    ];

    // `-y` truncates its target immediately, so ffmpeg never writes to the
    // user-chosen path directly: a failed or cancelled encode must not
    // destroy a video that already existed there. The destination is only
    // replaced once an encode has succeeded.
    final partialPath = '$outputPath.icarus-partial.mp4';
    Future<void> removePartialOutput() async {
      try {
        final partial = File(partialPath);
        if (await partial.exists()) await partial.delete();
      } on Object {
        // Best effort only.
      }
    }

    var lastLog = '';
    var lastExitCode = 0;
    var sizeRetries = 0;
    while (true) {
      var retryForSize = false;
      final codecAttempts = _codecAttempts(
        quality: quality,
        socialBitrate: socialBitrate,
      );
      for (var codecIndex = 0;
          codecIndex < codecAttempts.length;
          codecIndex++) {
        final codec = codecAttempts[codecIndex];
        // Reserve one progress slot for every possible invocation. A Social
        // size correction therefore continues from halfway instead of
        // making the dialog jump backward to the start of encoding. Max's
        // codec fallback gets the same monotonic behavior.
        final attemptCount =
            quality == VideoExportQuality.social ? 2 : codecAttempts.length;
        final attemptIndex =
            quality == VideoExportQuality.social ? sizeRetries : codecIndex;
        final attemptStart = attemptIndex / attemptCount;
        final attemptWeight = 1 / attemptCount;
        if (_cancelled) {
          await removePartialOutput();
          throw VideoExportCancelled();
        }
        // This encoder always produces MP4. Declaring the muxer explicitly
        // avoids relying on FFmpeg to infer it from the selected path.
        final args = [...baseArgs, ...codec, '-f', 'mp4', partialPath];
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
            final attemptFraction = (seconds / totalSeconds).clamp(0.0, 1.0);
            onProgress?.call(
              (attemptStart + attemptFraction * attemptWeight).clamp(
                0.0,
                1.0,
              ),
            );
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
          if (quality == VideoExportQuality.social) {
            final actualBytes = await File(partialPath).length();
            if (actualBytes > SocialVideoExportPolicy.targetFileSizeBytes &&
                sizeRetries < 1) {
              final retryBitrate = SocialVideoExportPolicy.retryVideoBitrate(
                previousBitrate: socialBitrate!,
                actualBytes: actualBytes,
              );
              if (retryBitrate != null) {
                socialBitrate = retryBitrate;
                sizeRetries++;
                retryForSize = true;
                break;
              }
            }
          }

          try {
            await _replaceDestination(partialPath, outputPath);
          } on Object catch (error) {
            await removePartialOutput();
            throw VideoExportException(
              'Could not write the video to the selected location: $error',
            );
          }
          onProgress?.call(1.0);
          return;
        }
        lastLog = stderrBuffer.toString();
        lastExitCode = exitCode;
        log(
          'ffmpeg (${codec.join(' ')}) exited with $exitCode',
          error: lastLog,
        );
      }
      if (retryForSize) continue;
      break;
    }
    await removePartialOutput();
    final tail = lastLog.split('\n').where((l) => l.trim().isNotEmpty).toList();
    final detail = tail.reversed.firstWhere(
      (line) {
        final trimmed = line.trim();
        return trimmed != 'Conversion failed!' &&
            !trimmed.startsWith('Error opening output file') &&
            !trimmed.startsWith('Error opening output files:');
      },
      orElse: () => tail.isEmpty ? 'unknown error' : tail.last,
    );
    throw VideoExportException(
      'ffmpeg failed (exit $lastExitCode): ${detail.trim()}',
    );
  }

  static List<List<String>> _codecAttempts({
    required VideoExportQuality quality,
    required int? socialBitrate,
  }) {
    if (quality == VideoExportQuality.social) {
      final bitrate = socialBitrate!;
      if (Platform.isWindows) {
        return [
          [
            '-c:v',
            'h264_mf',
            '-rate_control',
            'cbr',
            '-scenario',
            'archive',
            '-quality',
            '80',
            '-b:v',
            '$bitrate',
          ],
        ];
      }
      return [
        [
          '-c:v',
          'libx264',
          '-b:v',
          '$bitrate',
          '-maxrate',
          '$bitrate',
          '-bufsize',
          '${bitrate * 2}',
          '-preset',
          'medium',
        ],
      ];
    }

    return Platform.isWindows
        ? [
            ['-c:v', 'h264_mf', '-b:v', '8M'],
            ['-c:v', 'mpeg4', '-q:v', '3'],
          ]
        : [
            ['-c:v', 'libx264', '-crf', '20', '-preset', 'medium'],
            ['-c:v', 'mpeg4', '-q:v', '3'],
          ];
  }

  /// Moves the finished encode over the destination. The partial file lives
  /// in the destination's directory, so this is a same-volume rename, which
  /// replaces the destination atomically. There is deliberately no copy
  /// fallback: a copy truncates the destination before it completes, so a
  /// mid-copy failure would damage the very video the partial file protects.
  /// If the rename fails the caller surfaces the error and the existing
  /// destination is left untouched.
  static Future<void> _replaceDestination(String from, String to) =>
      File(from).rename(to);
}
