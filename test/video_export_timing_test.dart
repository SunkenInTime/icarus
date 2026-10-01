import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/services/video_export/video_export_quality.dart';
import 'package:icarus/services/video_export/video_exporter.dart';

void main() {
  setUp(() {
    CoordinateSystem(playAreaSize: const Size(1600, 900));
  });

  group('VideoExporter frame schedule', () {
    test('plans two-page Max duration from scheduled transition frames', () {
      expect(
        VideoExporter.plannedDurationSeconds(
          pageCount: 2,
          stepSeconds: 3,
          fps: VideoExportQuality.max.fps,
        ),
        closeTo(6 + 25 / 60, 1e-12),
      );
    });

    test('plans two-page Social duration from scheduled transition frames', () {
      expect(
        VideoExporter.plannedDurationSeconds(
          pageCount: 2,
          stepSeconds: 3,
          fps: VideoExportQuality.social.fps,
        ),
        closeTo(6 + 13 / 30, 1e-12),
      );
    });

    test('plans two-page Potato duration from scheduled transition frames', () {
      expect(
        VideoExporter.plannedDurationSeconds(
          pageCount: 2,
          stepSeconds: 3,
          fps: VideoExportQuality.potato.fps,
        ),
        closeTo(6 + 13 / 30, 1e-12),
      );
    });

    test('rejects a non-positive frame rate', () {
      expect(
        () => VideoExporter.transitionFrameCountFor(0),
        throwsArgumentError,
      );
    });
  });

  group('VideoExporter screenshot mode cleanup', () {
    test('restores the previous mode after a successful export operation',
        () async {
      CoordinateSystem.instance.setIsScreenshot(false);

      await runPreservingScreenshotMode(() async {
        CoordinateSystem.instance.setIsScreenshot(true);
      });

      expect(CoordinateSystem.instance.isScreenshot, isFalse);
    });

    test('restores the previous mode after a failed export operation',
        () async {
      CoordinateSystem.instance.setIsScreenshot(false);

      await expectLater(
        runPreservingScreenshotMode<void>(() async {
          CoordinateSystem.instance.setIsScreenshot(true);
          throw StateError('render failed');
        }),
        throwsStateError,
      );

      expect(CoordinateSystem.instance.isScreenshot, isFalse);
    });
  });
}
