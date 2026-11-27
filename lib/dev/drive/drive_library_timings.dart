import 'dart:io';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/agent_provider.dart';
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

Future<String> editToSavedLine(ProviderContainer c, {required int runs}) async {
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
  for (var run = 1; run <= runs; run++) {
    c.read(agentProvider.notifier).addAgent(PlacedAgent(
          id: 'timed-edit-$run',
          type: AgentType.jett,
          position: Offset(400.0 + run * 3, 400),
          isAlly: true,
        ));
    final clock = Stopwatch()..start();
    await c.read(strategyProvider.notifier).forceSaveNow(id);
    times.add(clock.elapsed);
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return 'SAVETIME ${stored?.name} (${stored?.pages.length} pages, $items '
      'items): an agent added, then saved, $runs times: ${_spread(times)}';
}

String backupLine(List<Duration> times, int bytes) =>
    'BACKUPTIME the whole library, '
    '${const LocalLibrary().storedStrategies.length} strategies, '
    '${(bytes / 1024).toStringAsFixed(0)} KB, ${times.length} times: '
    '${_spread(times)}';
