import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/library_store/slowed_engine.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/local_library.dart';

String memoryLine(String label) =>
    'MEMORY $label: ${(ProcessInfo.currentRss / (1024 * 1024)).toStringAsFixed(0)} MB resident, '
    '${(ProcessInfo.maxRss / (1024 * 1024)).toStringAsFixed(0)} MB at most so far';

String _spread(List<Duration> times) {
  final sorted = [...times]..sort();
  String ms(Duration time) => (time.inMicroseconds / 1000).toStringAsFixed(1);
  return 'median ${ms(sorted[sorted.length ~/ 2])} ms, '
      'fastest ${ms(sorted.first)} ms, worst ${ms(sorted.last)} ms';
}

final class _Gaps {
  final _clock = Stopwatch();
  final gaps = <int>[];
  var _last = 0;
  var _running = false;

  void start() {
    gaps.clear();
    _clock
      ..reset()
      ..start();
    _last = 0;
    _running = true;
    Timer.run(_tick);
  }

  void _tick() {
    _gap();
    if (_running) Timer.run(_tick);
  }

  void _gap() {
    final now = _clock.elapsedMicroseconds;
    gaps.add(now - _last);
    _last = now;
  }

  void stop() {
    _gap();
    _running = false;
  }

  int get longest => gaps.fold(0, (most, gap) => gap > most ? gap : most);
}

Future<int> _idleGap() async {
  final idle = _Gaps()..start();
  await Future<void>.delayed(const Duration(milliseconds: 50));
  idle.stop();
  final sorted = [...idle.gaps]..sort();
  return sorted[sorted.length ~/ 2];
}

enum TimedEdit {
  addAgent('an agent added'),
  removeFirstDrawing('its first drawing removed');

  const TimedEdit(this.words);

  final String words;
}

Future<List<String>> editToSavedLines(
  ProviderContainer c, {
  required int runs,
  TimedEdit edit = TimedEdit.addAgent,
}) async {
  final id = c.read(strategyProvider).strategyId;
  if (id == null) throw StateError('no strategy is open to edit');
  final stored = const LocalLibrary().storedStrategy(id);
  final items = stored == null
      ? 0
      : stored.pages.fold(
          0,
          (sum, page) =>
              sum +
              page.agentData.length +
              page.abilityData.length +
              page.drawingData.length +
              page.textData.length +
              page.imageData.length +
              page.utilityData.length,
        );
  final times = <Duration>[];
  final longest = <Duration>[];
  final waited = <Duration>[];
  final notWaiting = <Duration>[];
  final idleGaps = <Duration>[];
  final ticker = _Gaps();
  for (var run = 1; run <= runs; run++) {
    if (edit == TimedEdit.removeFirstDrawing &&
        c.read(drawingProvider).elements.isEmpty) {
      break;
    }
    switch (edit) {
      case TimedEdit.addAgent:
        c.read(agentProvider.notifier).addAgent(PlacedAgent(
              id: 'timed-edit-$run',
              type: AgentType.jett,
              position: Offset(400.0 + run * 3, 400),
              isAlly: true,
            ));
      case TimedEdit.removeFirstDrawing:
        c.read(drawingProvider.notifier).deleteDrawing(0);
    }
    await WidgetsBinding.instance.endOfFrame;
    final idle = await _idleGap();
    SlowedEngine.waitedMicros = 0;
    ticker.start();
    final clock = Stopwatch()..start();
    try {
      await c.read(strategyProvider.notifier).forceSaveNow(id);
      times.add(clock.elapsed);
    } finally {
      ticker.stop();
    }
    longest.add(Duration(microseconds: ticker.longest));
    waited.add(Duration(microseconds: SlowedEngine.waitedMicros));
    notWaiting.add(times.last - waited.last);
    idleGaps.add(Duration(microseconds: idle));
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  final page = 'SAVETIME ${stored?.name} (${stored?.pages.length} pages, '
      '$items items): ${edit.words}, then saved, ${times.length} times';
  if (times.isEmpty) return ['$page: the page has no drawing to remove'];
  return [
    '$page: ${_spread(times)}',
    '$page, the main thread held in one stretch: ${_spread(longest)}',
    '$page, waiting on the engine: ${_spread(waited)}',
    '$page, not waiting on the engine (the most the main thread can be '
        'busy): ${_spread(notWaiting)}',
    '$page, the main thread\'s idle tick before the save: '
        '${_spread(idleGaps)}',
  ];
}

String backupLine(List<Duration> times, int bytes) =>
    'BACKUPTIME the whole library, '
    '${const LocalLibrary().storedStrategies.length} strategies, '
    '${(bytes / 1024).toStringAsFixed(0)} KB, ${times.length} times: '
    '${_spread(times)}';
