import 'dart:io';

import 'package:icarus/dev/drive/drive_library_store.dart';
import 'package:icarus_library/icarus_library.dart' show shownTakesChecked;
import 'package:icarus_library/take_cost.dart';

final class PageTakeBudget {
  const PageTakeBudget({required this.longestStepMs, required this.recordMs});

  final num longestStepMs;
  final num recordMs;
}

String _ms(int micros) => (micros / 1000).toStringAsFixed(2);

Future<TakeTimes> _timed(
  Directory folder,
  int items,
  int changed,
  int runs, {
  required bool checked,
}) async {
  shownTakesChecked = checked;
  final bench = await Bench.open(folder, items, checked ? 'checked' : 'plain');
  try {
    return await timeTakes(bench, changed: changed, runs: runs);
  } finally {
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
  final TakeTimes plain;
  final TakeTimes checked;
  try {
    plain = await _timed(folder, items, changed, runs, checked: false);
    checked = await _timed(folder, items, changed, runs, checked: true);
  } on TakeCostFailed catch (failed) {
    throw StoreStepFailed(['TAKE could not be measured: $failed']);
  } finally {
    shownTakesChecked = checkedBefore;
    await folder.delete(recursive: true);
  }
  final label = 'TAKE $changed of $items items changed';
  final line =
      '$label, $runs results: longest step median '
      '${_ms(plain.longestMedian)} ms, worst ${_ms(plain.longestWorst)} ms; '
      'record median ${_ms(plain.wallMedian)} ms, worst '
      '${_ms(plain.wallWorst)} ms; with each take checked against one from '
      'scratch, as driver builds run: longest step median '
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
            ? '$label over budget: $name ${_ms(micros)} ms, target '
                  '$targetMs ms, over by '
                  '${_ms(micros - (targetMs * 1000).round())} ms'
            : '$label within budget: $name ${_ms(micros)} ms, target '
                  '$targetMs ms',
      ),
  ];
  final lines = [line, for (final judgement in judged) judgement.line];
  if (judged.any((judgement) => judgement.over)) {
    throw StoreStepFailed(lines);
  }
  return lines;
}
