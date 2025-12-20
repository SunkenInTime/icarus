import 'dart:async';
import 'package:flutter/scheduler.dart';

class PerfLogger {
  static final List<FrameTiming> _buffer = [];
  static Timer? _timer;

  static void start() {
    SchedulerBinding.instance.addTimingsCallback(_onTimings);

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final n = _buffer.length;
      if (n < 10) {
        _buffer.clear();
        return;
      }

      final uiTimes = _buffer
          .map((t) => t.buildDuration.inMicroseconds / 1000.0)
          .toList()
        ..sort();


      final rasterTimes = _buffer
          .map((t) => t.rasterDuration.inMicroseconds / 1000.0)
          .toList()
        ..sort();

      final totalTimes = _buffer
          .map((t) => t.totalSpan.inMicroseconds / 1000.0)
          .toList()
        ..sort();
      
      final gapTimes = List<double>.generate(n, (i) {
        final gap = totalTimes[i] - (uiTimes[i] + rasterTimes[i]);
        return gap < 0 ? 0 : gap; // clamp, just in case
      });
      gapTimes.sort();

      double p95(List<double> v) => v[(v.length * 0.95).floor()];
      double avg(List<double> v) => v.reduce((a, b) => a + b) / v.length;
      double maxV(List<double> v) => v.last;

      final jankyFrames =
          _buffer.where((t) => t.totalSpan.inMicroseconds > 16667).length;
      final jankPct = (jankyFrames / n) * 100;

    print(
      '[flutter-perf] n=$n jank=${jankPct.toStringAsFixed(1)}% '
      'ui(avg=${avg(uiTimes).toStringAsFixed(2)} p95=${p95(uiTimes).toStringAsFixed(2)} max=${maxV(uiTimes).toStringAsFixed(2)})ms '
      'rast(avg=${avg(rasterTimes).toStringAsFixed(2)} p95=${p95(rasterTimes).toStringAsFixed(2)} max=${maxV(rasterTimes).toStringAsFixed(2)})ms '
      'gap(avg=${avg(gapTimes).toStringAsFixed(2)} p95=${p95(gapTimes).toStringAsFixed(2)} max=${maxV(gapTimes).toStringAsFixed(2)})ms '
      'total(avg=${avg(totalTimes).toStringAsFixed(2)} p95=${p95(totalTimes).toStringAsFixed(2)} max=${maxV(totalTimes).toStringAsFixed(2)})ms',
    );

      _buffer.clear();
    });
  }

  static void _onTimings(List<FrameTiming> timings) {
    _buffer.addAll(timings);
  }
}
