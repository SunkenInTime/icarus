import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/page_transition/agent_path.dart';
import 'package:icarus/page_transition/transition_planner.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/transition_provider.dart';
import 'package:icarus/screenshot/offscreen_capture.dart';
import 'package:icarus/screenshot/persistent_offscreen_renderer.dart';
import 'package:icarus/screenshot/screenshot_view.dart';
import 'package:icarus/services/video_export/ffmpeg_png_sequence_writer.dart';
import 'package:icarus/services/video_export/ffmpeg_video_encoder.dart';
import 'package:icarus/view_cone/vision_geometry.dart';
import 'package:icarus/widgets/page_transition_overlay.dart';
import 'package:path/path.dart' as p;

/// Renders a strategy's selected pages into an .mp4 slideshow: each page is
/// held for the step duration, with full-fidelity page transitions between
/// consecutive included pages (ADR 0002).
class VideoExporter {
  VideoExporter({
    required this.strategy,
    required this.strategyState,
    required this.mapState,
    required this.geometry,
  });

  final StrategyData strategy;
  final StrategyState strategyState;
  final MapState mapState;
  final VisionGeometryMap? geometry;

  static const int fps = 60;

  static int get transitionFrameCount =>
      (kPageTransitionDuration.inMilliseconds * fps / 1000).round();

  /// Duration the 60 fps video can represent for one page transition.
  static double get encodedTransitionSeconds => transitionFrameCount / fps;

  static double plannedDurationSeconds({
    required int pageCount,
    required double stepSeconds,
  }) {
    if (pageCount <= 0) return 0;
    return pageCount * stepSeconds + (pageCount - 1) * encodedTransitionSeconds;
  }

  /// Frame-rendering dominates wall time; encoding is the short tail.
  static const double _renderWeight = 0.85;

  bool _cancelled = false;
  final FfmpegVideoEncoder _encoder = FfmpegVideoEncoder();
  FfmpegPngSequenceWriter? _frameWriter;

  void cancel() {
    _cancelled = true;
    // export()'s cleanup awaits the writer's termination; here we only need
    // to interrupt the processes.
    unawaited(_frameWriter?.cancel());
    _encoder.cancel();
  }

  Future<void> export({
    required List<StrategyPage> pages,
    required Duration stepDuration,
    required String ffmpegBinary,
    required String outputPath,
    void Function(double fraction, String label)? onProgress,
  }) async {
    if (pages.isEmpty) {
      throw VideoExportException('No pages selected.');
    }

    final transitionFrames = transitionFrameCount;
    const frameInterval = 1.0 / fps;
    final stepSeconds = stepDuration.inMilliseconds / 1000.0;
    final totalFrames = pages.length + (pages.length - 1) * transitionFrames;
    final totalSeconds = plannedDurationSeconds(
      pageCount: pages.length,
      stepSeconds: stepSeconds,
    );

    final tempDir =
        await Directory.systemTemp.createTemp('icarus_video_export_');
    ProviderContainer? captureContainer;
    PersistentOffscreenRenderer? renderer;
    FfmpegPngSequenceWriter? frameWriter;
    try {
      final offscreenContainer = ProviderContainer();
      captureContainer = offscreenContainer;
      renderer = PersistentOffscreenRenderer(
        targetSize: CoordinateSystem.screenShotSize,
        wrapWidget: (child) => wrapForOffscreenCapture(
          child,
          container: offscreenContainer,
        ),
      );
      frameWriter = FfmpegPngSequenceWriter();
      _frameWriter = frameWriter;
      await frameWriter.start(
        binary: ffmpegBinary,
        workingDirectory: tempDir.path,
        width: CoordinateSystem.screenShotSize.width.round(),
        height: CoordinateSystem.screenShotSize.height.round(),
        fps: fps,
        totalFrames: totalFrames,
      );
      final concatLines = <String>['ffconcat version 1.0'];
      var frameIndex = 0;
      var renderedFrames = 0;
      String? lastFrameFile;

      Future<void> renderFrame(Widget view, double durationSeconds) async {
        if (_cancelled) throw VideoExportCancelled();
        final bytes = await renderer!.captureRawRgba(view);
        final fileName = 'frame_${frameIndex.toString().padLeft(5, '0')}.png';
        await frameWriter!.writeFrame(bytes);
        frameIndex++;
        concatLines
          ..add("file '$fileName'")
          ..add('duration ${durationSeconds.toStringAsFixed(6)}');
        lastFrameFile = fileName;
        renderedFrames++;
        onProgress?.call(
          renderedFrames / totalFrames * _renderWeight,
          'Rendering frames ($renderedFrames/$totalFrames)',
        );
      }

      // Warm the first page's SVGs and image streams once. Later pages get a
      // shorter warm-up immediately before their transition begins; the 60
      // fps transition frames themselves never pay a fixed settling delay.
      await renderer.prepare(
        _stillView(pages.first),
        settleDuration: const Duration(milliseconds: 800),
      );

      for (var i = 0; i < pages.length; i++) {
        final page = pages[i];
        await renderFrame(_stillView(page), stepSeconds);

        if (i + 1 >= pages.length) continue;
        final nextPage = pages[i + 1];
        final entries = TransitionPlanner.diff(
          TransitionPlanner.placedWidgetMapForPage(page),
          TransitionPlanner.placedWidgetMapForPage(nextPage),
        );
        final fadeDrawings = TransitionPlanner.drawingsChanged(
          page.drawingData,
          nextPage.drawingData,
        );
        final agentPaths = AgentTransitionPathPlanner.plan(
          entries: entries,
          geometry: geometry,
          isAttack: nextPage.isAttack,
          startAgentSize: page.settings.agentSize,
          endAgentSize: nextPage.settings.agentSize,
          coordinateSystem: CoordinateSystem.instance,
        );
        await renderer.prepare(
          _stillView(nextPage),
          settleDuration: const Duration(milliseconds: 120),
        );
        for (var f = 1; f <= transitionFrames; f++) {
          final t = kPageTransitionCurve.transform(f / transitionFrames);
          await renderFrame(
            _transitionView(
              from: page,
              to: nextPage,
              entries: entries,
              agentPaths: agentPaths,
              t: t,
              fadeDrawings: fadeDrawings,
            ),
            frameInterval,
          );
        }
      }

      await frameWriter.finish();
      _frameWriter = null;

      // The concat demuxer ignores the duration of the final entry unless the
      // last file is repeated.
      if (lastFrameFile != null) {
        concatLines.add("file '$lastFrameFile'");
      }
      final concatFile = File(p.join(tempDir.path, 'frames.ffconcat'));
      await concatFile.writeAsString(concatLines.join('\n'));

      if (_cancelled) throw VideoExportCancelled();
      onProgress?.call(_renderWeight, 'Encoding video');
      await _encoder.encode(
        binary: ffmpegBinary,
        workingDirectory: tempDir.path,
        concatListFileName: 'frames.ffconcat',
        outputPath: outputPath,
        totalSeconds: totalSeconds,
        onProgress: (fraction) => onProgress?.call(
          _renderWeight + fraction * (1 - _renderWeight),
          'Encoding video',
        ),
      );
    } finally {
      // Wait for ffmpeg to exit before deleting the directory it writes into;
      // on Windows the delete races a still-exiting process otherwise.
      await frameWriter?.cancel();
      _frameWriter = null;
      try {
        await renderer?.dispose();
      } finally {
        captureContainer?.dispose();
        try {
          await tempDir.delete(recursive: true);
        } on Object {
          // Leaving orphaned temp frames behind is preferable to masking the
          // original export result.
        }
      }
    }
  }

  Widget _stillView(StrategyPage page) => _pageView(page);

  Widget _transitionView({
    required StrategyPage from,
    required StrategyPage to,
    required List<PageTransitionEntry> entries,
    required Map<String, AgentTransitionPath> agentPaths,
    required double t,
    required bool fadeDrawings,
  }) {
    double lerp(double a, double b) => a + (b - a) * t;
    return _pageView(
      to,
      placedWidgetsOverride: TransitionEntriesLayer(
        entries: entries,
        agentPaths: agentPaths,
        t: t,
        direction: PageTransitionDirection.forward,
        agentSize: lerp(from.settings.agentSize, to.settings.agentSize),
        abilitySize: lerp(from.settings.abilitySize, to.settings.abilitySize),
      ),
      drawingsOpacity: fadeDrawings ? earlyFadeInOpacity(t) : 1.0,
    );
  }

  Widget _pageView(
    StrategyPage page, {
    Widget? placedWidgetsOverride,
    double drawingsOpacity = 1.0,
  }) {
    return ScreenshotView(
      isAttack: page.isAttack,
      mapValue: strategy.mapData,
      showSpawnBarrier: mapState.showSpawnBarrier,
      showRegionNames: mapState.showRegionNames,
      showUltOrbs: mapState.showUltOrbs,
      agents: page.agentData,
      abilities: page.abilityData,
      text: page.textData,
      images: page.imageData,
      drawings: page.drawingData,
      utilities: page.utilityData,
      strategySettings: page.settings,
      strategyState: strategyState,
      pageName: page.name,
      lineUpGroups: page.lineUpGroups,
      themeProfileId: strategy.themeProfileId,
      themeOverridePalette: strategy.themeOverridePalette,
      placedWidgetsOverride: placedWidgetsOverride,
      drawingsOpacity: drawingsOpacity,
    );
  }
}
