import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:icarus/dev/drive/drive_library_store.dart';
import 'package:icarus_library/icarus_library.dart' show shownTakesChecked;
import 'package:icarus_library/take_cost.dart';

final class PageTakeBudget {
  const PageTakeBudget({required this.longestStepMs, required this.recordMs});

  final num longestStepMs;
  final num recordMs;
}

String _ms(int micros) => (micros / 1000).toStringAsFixed(2);

Future<String> pcBusy() async {
  try {
    if (Platform.isWindows) {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        "[math]::Round((Get-Counter '\\Processor(_Total)\\% Processor Time' "
            '-SampleInterval 1 -MaxSamples 1).CounterSamples[0].CookedValue, 1)',
      ]);
      return '${'${result.stdout}'.trim()}%';
    }
    if (Platform.isLinux) {
      Future<List<int>> ticks() async =>
          (await File('/proc/stat').readAsLines())
              .first
              .split(RegExp(r'\s+'))
              .skip(1)
              .map(int.parse)
              .toList();
      final before = await ticks();
      await Future<void>.delayed(const Duration(seconds: 1));
      final after = await ticks();
      final spent = [
        for (var i = 0; i < after.length; i++) after[i] - before[i]
      ];
      final total = spent.fold(0, (sum, each) => sum + each);
      final idle = spent[3] + spent[4];
      return '${(100 * (total - idle) / total).toStringAsFixed(1)}%';
    }
  } on Object catch (error) {
    return 'unknown ($error)';
  }
  return 'unknown';
}

final class _Frames {
  int drawn = 0;

  void count(List<FrameTiming> timings) => drawn += timings.length;
}

Future<(TakeTimes, int)> _timed(
  Directory folder,
  int items,
  int changed,
  int runs, {
  required bool checked,
}) async {
  shownTakesChecked = checked;
  final frames = _Frames();
  final bench = await Bench.open(folder, items, checked ? 'checked' : 'plain');
  SchedulerBinding.instance.addTimingsCallback(frames.count);
  try {
    final times = await timeTakes(bench, changed: changed, runs: runs);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    return (times, frames.drawn);
  } finally {
    SchedulerBinding.instance.removeTimingsCallback(frames.count);
    await bench.close();
  }
}

Future<List<String>> pageTakeCost({
  required int items,
  required int changed,
  int runs = 51,
  PageTakeBudget? budget,
}) async {
  final folder = await Directory.systemTemp.createTemp('icarus_page_take');
  final checkedBefore = shownTakesChecked;
  final busyBefore = await pcBusy();
  final TakeTimes plain;
  final int framesDrawn;
  final TakeTimes checked;
  try {
    (plain, framesDrawn) = await _timed(
      folder,
      items,
      changed,
      runs,
      checked: false,
    );
    (checked, _) = await _timed(folder, items, changed, runs, checked: true);
  } on TakeCostFailed catch (failed) {
    throw StoreStepFailed(['TAKE could not be measured: $failed']);
  } finally {
    shownTakesChecked = checkedBefore;
    await folder.delete(recursive: true);
  }
  final busyAfter = await pcBusy();
  final label = 'TAKE $changed of $items items changed';
  final line = '$label, $runs results: longest step median '
      '${_ms(plain.longestMedian)} ms, worst ${_ms(plain.longestWorst)} ms; '
      'record median ${_ms(plain.wallMedian)} ms, worst '
      '${_ms(plain.wallWorst)} ms; main isolate busy median '
      '${_ms(plain.busyMedian)} ms; $framesDrawn frames drawn meanwhile; '
      'PC busy $busyBefore before, $busyAfter after; with each take checked '
      'against one from scratch, as driver builds run: longest step median '
      '${_ms(checked.longestMedian)} ms, record median '
      '${_ms(checked.wallMedian)} ms';
  if (budget == null) return [line];
  final judged = [
    for (final (name, micros, targetMs) in [
      ('longest step', plain.longestMedian, budget.longestStepMs),
      ('record', plain.wallMedian, budget.recordMs),
    ])
      (
        over: micros / 1000 > targetMs,
        line: micros / 1000 > targetMs
            ? '$label over budget: $name median of $runs takes '
                '${_ms(micros)} ms, target $targetMs ms, over by '
                '${_ms(micros - (targetMs * 1000).round())} ms; PC busy '
                '$busyBefore before, $busyAfter after'
            : '$label within budget: $name median of $runs takes '
                '${_ms(micros)} ms, target $targetMs ms',
      ),
  ];
  final lines = [line, for (final judgement in judged) judgement.line];
  if (judged.any((judgement) => judgement.over)) {
    throw StoreStepFailed(lines);
  }
  return lines;
}
