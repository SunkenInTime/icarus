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
      'unitsWithFindings': t.unitsWithFindings,
      'noFinding': t.noFinding,
      'changedWithoutAction': t.changedWithoutAction,
      'beforeNotOnCanvas': t.beforeNotOnCanvas,
      'opsWrong': t.opsWrong,
      'notJudged': t.unitsNotJudged,
      'discarded': t.unitsDiscarded,
      'commitsRefused': t.commitsRefused.length,
      'followerFaults': t.followerFaults.length,
      'hiveSavesDifferent': t.hiveSavesDifferent,
    };

String _reasons(Map<String, int> counts) =>
    counts.isEmpty ? '' : ' (${_counted(counts)})';

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

List<String> actionOpsLines(String label, ActionJournal journal) {
  final t = journal.tally;
  return [
    'OPS $label gap finder: a finding is evidence of a gap; a unit with no '
        'finding is evidence of nothing',
    'OPS $label units opened ${t.unitsOpened}: with a finding '
        '${t.unitsWithFindings} (changed without an action '
        '${t.changedWithoutAction}, the action\'s before did not match the '
        'canvas ${t.beforeNotOnCanvas}, ops wrong ${t.opsWrong}), no finding '
        '${t.noFinding}, no change ${t.unitsWithNoChange}, not judged '
        '${t.unitsNotJudged}${_reasons(t.notJudged)}, discarded '
        '${t.unitsDiscarded}${_reasons(t.discarded)}, still open '
        '${journal.unitsStillOpen}; adds up ${journal.addsUp ? 'yes' : 'NO'}',
    'OPS $label actions ${t.actions}, commits ${t.commits}, ops '
        '${t.opsCommitted}, commits refused ${t.commitsRefused.length}; '
        'taken up ${t.takenUp}, released ${t.released} (Hive put back '
        '${t.releasesThatPutHiveBack}), store put right from the canvas '
        '${t.repairsFromCanvas} after a unit and ${t.repairsAtLoad} at a '
        'page load; follower faults ${t.followerFaults.length}',
    'OPS $label opened with the canvas different from Hive '
        '${t.openedDifferentFromHive} times'
        '${t.openedDifferences.isEmpty ? '' : ': ${_counted(t.openedDifferences)}'}',
    'OPS $label hive saves ${t.hiveSaves}: equal to the store '
        '${t.hiveSavesEqualToStore}, different ${t.hiveSavesDifferent}, '
        'failed ${t.hiveSavesFailed}'
        '${t.hiveDifferencesByField.isEmpty ? '' : '; differing fields ${_counted(t.hiveDifferencesByField)}'}',
    for (final MapEntry(key: kind, value: k) in t.byKind.entries)
      'OPS $label kind "$kind": with a finding ${k.withFindings} (changed '
          'without an action ${k.changedWithoutAction}, the action\'s before '
          'did not match the canvas ${k.beforeNotOnCanvas}, ops wrong '
          '${k.opsWrong}), no finding ${k.noFinding}, no change '
          '${k.noChange}, not judged ${_sum(k.notJudged)}'
          '${_reasons(k.notJudged)}, discarded ${_sum(k.discarded)}'
          '${_reasons(k.discarded)}',
    for (final f in t.findings)
      'OPS $label finding ${f.number} "${f.kind}"'
          '${_listed(' changed without an action: ', f.uncovered)}'
          '${_listed(' | the action\'s before did not match the canvas: ', f.stale)}'
          '${_listed(' | ops wrong: ', f.wrong)}'
          '${f.gaps.isEmpty ? '' : ' | gaps: ${f.gaps.take(6).join('; ')}'}',
    for (final refused in t.commitsRefused) 'OPS $label refused $refused',
    for (final fault in t.followerFaults) 'OPS $label follower fault $fault',
    for (final h in t.hiveFindings)
      'OPS $label hive save ${h.save} differs from the store: '
          '${h.differences.take(12).join('; ')}',
    ..._costLines(label, t.costs),
  ];
}

int _sum(Map<String, int> counts) => counts.values.fold(0, (a, b) => a + b);

String _listed(String heading, List<String> lines) => lines.isEmpty
    ? ''
    : '$heading${lines.take(12).join('; ')}'
        '${lines.length > 12 ? ' (+${lines.length - 12})' : ''}';

String _notAddingUp(ActionJournal journal) =>
    'units do not add up: opened ${journal.tally.unitsOpened}, given a '
    'disposition ${journal.tally.unitsDisposed}, still open '
    '${journal.unitsStillOpen}';

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
  final lines = actionOpsLines(label, journal);
  final counts = opsCounts(journal.tally);
  final problems = [
    if (!journal.addsUp) _notAddingUp(journal),
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
      final journal? => actionOpsLines('run', journal),
      null => const [],
    };

String? actionOpsEndProblem(StoreMirror mirror) => switch (mirror.actions) {
      final journal? when !journal.addsUp || journal.unitsStillOpen > 0 =>
        'OPS run ${_notAddingUp(journal)}',
      _ => null,
    };
