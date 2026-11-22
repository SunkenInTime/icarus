import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';

sealed class UiStats {
  const UiStats(this.longestMainBlock);

  final Duration longestMainBlock;
}

final class UiFramesMeasured extends UiStats {
  const UiFramesMeasured({
    required Duration longestMainBlock,
    required this.frames,
    required this.worstFrameGap,
    required this.frameGapsOver50ms,
    required this.worstBuild,
    required this.worstRaster,
  }) : super(longestMainBlock);

  final int frames;
  final Duration worstFrameGap;
  final int frameGapsOver50ms;
  final Duration worstBuild;
  final Duration worstRaster;

  @override
  String toString() =>
      'longest main isolate block ${longestMainBlock.inMilliseconds} ms; '
      'frames $frames, worst gap ${worstFrameGap.inMilliseconds} ms, '
      'gaps over 50 ms $frameGapsOver50ms, worst build '
      '${worstBuild.inMilliseconds} ms, worst raster '
      '${worstRaster.inMilliseconds} ms';
}

final class UiNoFrames extends UiStats {
  const UiNoFrames(super.longestMainBlock);

  @override
  String toString() =>
      'longest main isolate block ${longestMainBlock.inMilliseconds} ms; '
      'no frame was drawn';
}

final class UiWatch {
  var _watching = false;
  var _longestMainBlock = Duration.zero;
  var _frames = 0;
  var _frameGapsOver50ms = 0;
  var _worstFrameGap = Duration.zero;
  var _worstBuild = Duration.zero;
  var _worstRaster = Duration.zero;

  void _noteTimings(List<ui.FrameTiming> timings) {
    for (final timing in timings) {
      if (timing.buildDuration > _worstBuild)
        _worstBuild = timing.buildDuration;
      if (timing.rasterDuration > _worstRaster) {
        _worstRaster = timing.rasterDuration;
      }
    }
  }

  Future<void> _watchFrames() async {
    final scheduler = SchedulerBinding.instance;
    var last = Stopwatch()..start();
    while (_watching) {
      scheduler.scheduleFrame();
      await scheduler.endOfFrame;
      if (!_watching) return;
      final gap = last.elapsed;
      last = Stopwatch()..start();
      _frames++;
      if (gap > _worstFrameGap) _worstFrameGap = gap;
      if (gap.inMilliseconds > 50) _frameGapsOver50ms++;
    }
  }

  Future<void> _watchMain() async {
    var last = Stopwatch()..start();
    while (_watching) {
      await Future<void>.delayed(Duration.zero);
      if (last.elapsed > _longestMainBlock) _longestMainBlock = last.elapsed;
      last = Stopwatch()..start();
    }
  }

  void start() {
    _watching = true;
    SchedulerBinding.instance.addTimingsCallback(_noteTimings);
    unawaited(_watchFrames());
    unawaited(_watchMain());
  }

  UiStats stop() {
    if (_watching) {
      _watching = false;
      SchedulerBinding.instance.removeTimingsCallback(_noteTimings);
    }
    return _frames == 0
        ? UiNoFrames(_longestMainBlock)
        : UiFramesMeasured(
            longestMainBlock: _longestMainBlock,
            frames: _frames,
            worstFrameGap: _worstFrameGap,
            frameGapsOver50ms: _frameGapsOver50ms,
            worstBuild: _worstBuild,
            worstRaster: _worstRaster,
          );
  }
}
