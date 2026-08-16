import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/video_export/ffmpeg_video_encoder.dart';
import 'package:icarus/services/video_export/video_export_quality.dart';

void main() {
  group('ensureMp4Extension', () {
    test('appends the extension when the save dialog omits it', () {
      expect(
          ensureMp4Extension(r'C:\Videos\strategy'), r'C:\Videos\strategy.mp4');
    });

    test('preserves an existing extension regardless of case', () {
      expect(ensureMp4Extension(r'C:\Videos\strategy.MP4'),
          r'C:\Videos\strategy.MP4');
    });
  });

  group('videoEncodeAttemptProgress', () {
    test('keeps a size-targeted retry monotonic', () {
      final callbacks = <double>[
        videoEncodeAttemptProgress(
          attemptIndex: 0,
          attemptCount: 2,
          attemptFraction: 0,
        ),
        videoEncodeAttemptProgress(
          attemptIndex: 0,
          attemptCount: 2,
          attemptFraction: 1,
        ),
        videoEncodeAttemptProgress(
          attemptIndex: 1,
          attemptCount: 2,
          attemptFraction: 0,
        ),
        videoEncodeAttemptProgress(
          attemptIndex: 1,
          attemptCount: 2,
          attemptFraction: 1,
        ),
      ];

      expect(callbacks, orderedEquals([0, 0.5, 0.5, 1]));
      for (var index = 1; index < callbacks.length; index++) {
        expect(callbacks[index], greaterThanOrEqualTo(callbacks[index - 1]));
      }
    });

    test('clamps progress reported outside the expected duration', () {
      expect(
        videoEncodeAttemptProgress(
          attemptIndex: 0,
          attemptCount: 2,
          attemptFraction: -0.5,
        ),
        0,
      );
      expect(
        videoEncodeAttemptProgress(
          attemptIndex: 1,
          attemptCount: 2,
          attemptFraction: 1.5,
        ),
        1,
      );
    });
  });

  group('videoExportFilter', () {
    test('keeps ordinary Potato exports at 1080p', () {
      expect(
        videoExportFilter(
          quality: VideoExportQuality.potato,
          totalSeconds: 22,
        ),
        'fps=30,format=yuv420p',
      );
    });

    test('downscales floor-bitrate Potato exports to 720p once', () {
      expect(
        videoExportFilter(
          quality: VideoExportQuality.potato,
          totalSeconds: 248,
        ),
        'fps=30,scale=1280:720:flags=lanczos,format=yuv420p',
      );
    });

    test('never downscales Social or Max', () {
      expect(
        videoExportFilter(
          quality: VideoExportQuality.social,
          totalSeconds: 1000,
        ),
        'fps=30,format=yuv420p',
      );
      expect(
        videoExportFilter(
          quality: VideoExportQuality.max,
          totalSeconds: 1000,
        ),
        'fps=60,format=yuv420p',
      );
    });
  });

  group('FfmpegVideoEncoder', () {
    test('rebuilds the Potato filter when a size retry reaches the floor',
        () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'icarus-video-encoder-test-',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final invocations = <List<String>>[];
      final encoder = FfmpegVideoEncoder(
        processStarter: (
          executable,
          arguments, {
          workingDirectory,
        }) async {
          final invocationIndex = invocations.length;
          invocations.add(List<String>.of(arguments));

          final partial = File(arguments.last);
          final output = await partial.open(mode: FileMode.write);
          await output.truncate(
            invocationIndex == 0
                ? VideoExportSizePolicies.potato.targetFileSizeBytes + 1
                : 1024,
          );
          await output.close();
          return _SuccessfulProcess();
        },
      );

      final outputPath = '${tempDir.path}${Platform.pathSeparator}result.mp4';
      await encoder.encode(
        binary: 'fake-ffmpeg',
        workingDirectory: tempDir.path,
        concatListFileName: 'frames.ffconcat',
        outputPath: outputPath,
        totalSeconds: 247,
        quality: VideoExportQuality.potato,
      );

      expect(invocations, hasLength(2));
      expect(_argumentAfter(invocations[0], '-vf'), 'fps=30,format=yuv420p');
      expect(
        _argumentAfter(invocations[1], '-vf'),
        'fps=30,scale=1280:720:flags=lanczos,format=yuv420p',
      );
      expect(
        _argumentAfter(invocations[1], '-b:v'),
        '${VideoExportSizePolicy.minVideoBitrate}',
      );
      expect(await File(outputPath).length(), 1024);
    });
  });
}

String _argumentAfter(List<String> arguments, String option) =>
    arguments[arguments.indexOf(option) + 1];

class _SuccessfulProcess implements Process {
  @override
  Future<int> get exitCode async => 0;

  @override
  int get pid => 0;

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  IOSink get stdin => throw UnsupportedError('stdin is unused by this test');

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}
