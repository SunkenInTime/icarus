import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';

final class RunFrames {
  var _frames = 0;
  var _over50ms = 0;
  var _worstFrame = Duration.zero;
  var _worstBuild = Duration.zero;
  var _worstRaster = Duration.zero;
  var _longestMainBlock = Duration.zero;
  Timer? _ticker;

  static const _tick = Duration(milliseconds: 5);

  void _note(List<ui.FrameTiming> timings) {
    for (final timing in timings) {
      _frames++;
      final span = timing.totalSpan;
      if (span > _worstFrame) _worstFrame = span;
      if (span.inMilliseconds > 50) _over50ms++;
      if (timing.buildDuration > _worstBuild)
        _worstBuild = timing.buildDuration;
      if (timing.rasterDuration > _worstRaster) {
        _worstRaster = timing.rasterDuration;
      }
    }
  }

  void start() {
    SchedulerBinding.instance.addTimingsCallback(_note);
    var last = Stopwatch()..start();
    _ticker = Timer.periodic(_tick, (_) {
      final late = last.elapsed - _tick;
      if (late > _longestMainBlock) _longestMainBlock = late;
      last = Stopwatch()..start();
    });
  }

  String stop() {
    SchedulerBinding.instance.removeTimingsCallback(_note);
    _ticker?.cancel();
    return 'FRAMES whole run: frames $_frames, worst frame '
        '${_worstFrame.inMilliseconds} ms (build ${_worstBuild.inMilliseconds} '
        'ms, raster ${_worstRaster.inMilliseconds} ms), frames over 50 ms '
        '$_over50ms, longest main isolate block '
        '${_longestMainBlock.inMilliseconds} ms';
  }
}
