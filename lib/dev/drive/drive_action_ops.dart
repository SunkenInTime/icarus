import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/dev/drive/drive_library_store.dart';
import 'package:icarus/library_store/action_journal.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

ActionJournal? _journal(ProviderContainer c) =>
    switch (c.read(shadowProvider.notifier).mode) {
      Mirroring(:final mirror) => mirror.actions,
      ShadowOnly() => null,
    };

String _counted(Map<String, int> counts) => [
      for (final key in counts.keys.toList()..sort()) '$key ${counts[key]}',
    ].join(', ');

Map<String, int> opsCounts(ActionOpsTally t) => {
      'unitsOpened': t.unitsOpened,
      'coveredAndCorrect': t.coveredAndCorrect,
      'changedWithoutAction': t.changedWithoutAction,
      'opsWrong': t.opsWrong,
      'notJudged': t.unitsNotJudged,
      'commitsRefused': t.commitsRefused.length,
      'followerFaults': t.followerFaults.length,
      'hiveSavesDifferent': t.hiveSavesDifferent,
    };

String _ms(Duration d) => (d.inMicroseconds / 1000).toStringAsFixed(1);

List<String> _costLines(String label, List<UnitCost> costs) {
  String spread(Iterable<Duration> values) {
    final sorted = [...values]..sort();
    if (sorted.isEmpty) return '-';
    return 'p50 ${_ms(sorted[sorted.length ~/ 2])} '
        'max ${_ms(sorted.last)} ms';
  }

  return [
    for (final (name, low, high) in [
      ('up to 50 items', 0, 50),
      ('51 to 500 items', 51, 500),
      ('over 500 items', 501, 1 << 30),
    ])
      if (costs.where((c) => c.items >= low && c.items <= high).toList()
          case final bucket when bucket.isNotEmpty)
        'OPS $label unit cost, page with $name: ${bucket.length} units; '
            'snapshot ${spread(bucket.map((c) => c.snapshot))}; '
            'replay ${spread(bucket.map((c) => c.replay))}; '
            'compare ${spread(bucket.map((c) => c.compare))}',
  ];
}

List<String> actionOpsLines(String label, ActionOpsTally t) => [
      'OPS $label units opened ${t.unitsOpened}: covered and correct '
          '${t.coveredAndCorrect}, changed without an action '
          '${t.changedWithoutAction}, ops wrong ${t.opsWrong} (both '
          '${t.bothChecksFailed}), not judged ${t.unitsNotJudged}'
          '${t.notJudged.isEmpty ? '' : ' (${_counted(t.notJudged)})'}; '
          'adds up ${t.addsUp ? 'yes' : 'NO'}; units with no change '
          '${t.unitsWithNoChange}',
      'OPS $label actions ${t.actions}, commits ${t.commits}, ops '
          '${t.opsCommitted}, commits refused ${t.commitsRefused.length}; '
          'taken up ${t.takenUp}, released ${t.released} (Hive put back '
          '${t.releasesThatPutHiveBack}), store put right from the canvas '
          '${t.repairsFromCanvas}; follower faults ${t.followerFaults.length}',
      'OPS $label hive saves ${t.hiveSaves}: equal to the store '
          '${t.hiveSavesEqualToStore}, different ${t.hiveSavesDifferent}, '
          'failed ${t.hiveSavesFailed}'
          '${t.hiveDifferencesByField.isEmpty ? '' : '; differing fields ${_counted(t.hiveDifferencesByField)}'}',
      for (final MapEntry(key: kind, value: k) in t.byKind.entries)
        'OPS $label kind "$kind": judged ${k.judged}, covered and correct '
            '${k.coveredAndCorrect}, changed without an action '
            '${k.changedWithoutAction}, ops wrong ${k.opsWrong}, not judged '
            '${k.notJudged.values.fold(0, (a, b) => a + b)}'
            '${k.notJudged.isEmpty ? '' : ' (${_counted(k.notJudged)})'}',
      for (final f in t.findings)
        'OPS $label unit ${f.number} "${f.kind}"'
            '${f.uncovered.isEmpty ? '' : ' changed without an action: ${f.uncovered.take(12).join('; ')}${f.uncovered.length > 12 ? ' (+${f.uncovered.length - 12})' : ''}'}'
            '${f.wrong.isEmpty ? '' : ' | ops wrong: ${f.wrong.take(12).join('; ')}${f.wrong.length > 12 ? ' (+${f.wrong.length - 12})' : ''}'}'
            '${f.gaps.isEmpty ? '' : ' | gaps: ${f.gaps.take(6).join('; ')}'}',
      for (final refused in t.commitsRefused) 'OPS $label refused $refused',
      for (final fault in t.followerFaults) 'OPS $label follower fault $fault',
      for (final h in t.hiveFindings)
        'OPS $label hive save ${h.save} differs from the store: '
            '${h.differences.take(12).join('; ')}',
      ..._costLines(label, t.costs),
    ];

String actionOpsInFlight(ProviderContainer c) => switch (_journal(c)) {
      final journal? => 'actions journaled ${journal.tally.actions}, '
          'ops landed in the store ${journal.tally.opsCommitted}',
      null => 'this run does not journal action ops',
    };

String? opStillPendingProblem(ProviderContainer c) => switch (_journal(c)) {
      final journal? when journal.tally.opsCommitted < journal.tally.actions =>
        null,
      final journal? => 'the stroke\'s op had already landed by the first '
          'frame after its release: ${journal.tally.opsCommitted} ops for '
          '${journal.tally.actions} actions',
      null => 'this run does not journal action ops',
    };

Future<void> _settled(StoreMirror mirror) async {
  await Future<void>.delayed(Duration.zero);
  await mirror.drained().timeout(const Duration(seconds: 60));
}

Future<List<String>> actionOpsStep(
  ProviderContainer c, {
  required String label,
  required Map<String, Object?> expected,
}) async {
  final journal = _journal(c) ??
      (throw StoreStepFailed(['this run does not journal action ops']));
  if (c.read(shadowProvider.notifier).mode case Mirroring(:final mirror)
      when mirror.phase is MirrorFollowing) {
    await _settled(mirror);
  }
  final lines = actionOpsLines(label, journal.tally);
  final counts = opsCounts(journal.tally);
  final problems = [
    if (!journal.tally.addsUp)
      'units do not add up: opened ${journal.tally.unitsOpened}, judged '
          '${journal.tally.unitsJudged}, not judged '
          '${journal.tally.unitsNotJudged}',
    for (final MapEntry(:key, :value) in expected.entries)
      if (counts[key] != value) '$key is ${counts[key]}, expected $value',
  ];
  if (problems.isNotEmpty) throw StoreStepFailed([...lines, ...problems]);
  return lines;
}

Future<String?> saveOpenLocalStrategy(
    ProviderContainer c, StoreMirror mirror) async {
  if (mirror.actions == null) return null;
  final strategy = c.read(strategyProvider);
  final id = strategy.strategyId;
  if (id == null || strategy.source != StrategySource.local) return null;
  try {
    await c.read(strategyProvider.notifier).forceSaveNow(id);
  } on StateError catch (error) {
    return 'OPS the open strategy could not be saved at the end: '
        '${error.message}';
  }
  await _settled(mirror);
  return null;
}

List<String> actionOpsEndLines(StoreMirror mirror) => switch (mirror.actions) {
      final journal? => [
          ...actionOpsLines('run', journal.tally),
          if (!journal.tally.addsUp)
            'OPS run units do not add up: opened '
                '${journal.tally.unitsOpened}, judged '
                '${journal.tally.unitsJudged}, not judged '
                '${journal.tally.unitsNotJudged}',
        ],
      null => const [],
    };
