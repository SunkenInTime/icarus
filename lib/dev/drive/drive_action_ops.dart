import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/dev/drive/drive_library_store.dart';
import 'package:icarus/library_store/action_journal.dart';
import 'package:icarus/library_store/action_ops.dart';
import 'package:icarus/library_store/ops_verdict.dart';
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
      for (final key in counts.keys.toList()..sort()) '$key=${counts[key]}',
    ].join(', ');

Map<String, int> opsCounts(ActionOpsTally t) => {
      'actions': t.actions,
      'actionsWithOps': t.actionsWithOps,
      'commits': t.commits,
      'commitsRefused': t.commitsRefused.length,
      'gaps': t.gaps.length,
      'saves': t.saves,
      'readBackEqual': t.readBackEqual,
      'readBackUnequal': t.readBackUnequal,
      'imageWroteNothing': t.imageWroteNothing,
      'imageWroteRows': t.imageWroteRows,
      'realRows': t.rowsByClass[ImageRowClass.real] ?? 0,
      'trashedPagesRemoved': t.trashedPagesRemoved,
      'deletedRowsRemoved': t.deletedRowsRemoved,
      'lineupsInsideGroups': t.lineupsInsideGroups,
      'lineupsChangingGroups': t.lineupsChangingGroups,
    };

String actionOpsInFlight(ProviderContainer c) => switch (_journal(c)) {
      final journal? => 'actions journaled ${journal.tally.actions}, '
          'ops landed in the store ${journal.tally.opsCommitted}',
      null => 'this run does not journal action ops',
    };

List<String> actionOpsLines(String label, ActionOpsTally t) => [
      'OPS $label actions ${t.actions}, ${t.actionsWithOps} with ops; '
          'commits ${t.commits}, ${t.opsCommitted} ops, '
          '${t.commitsWithNothingToSave} with nothing to save, '
          '${t.commitsRefused.length} refused; saves ${t.saves}: read back '
          'equal ${t.readBackEqual}, unequal ${t.readBackUnequal}, not in the '
          'store ${t.savesNotInStore}, not read ${t.savesNotRead}; image saves '
          'wrote nothing ${t.imageWroteNothing}, wrote rows ${t.imageWroteRows}',
      'OPS $label strategies removed before an image save because the '
          'store held what an image may not drop: trashed pages '
          '${t.trashedPagesRemoved}, deleted rows ${t.deletedRowsRemoved}; strategies repaired from Hive at the end '
          '${t.repairedAtEnd}, after ${t.actionsAfterLastSave} actions made '
          'after their last save',
      'OPS $label rows the image saves wrote: ${[
        for (final rowClass in ImageRowClass.values)
          '${rowClass.words} ${t.rowsByClass[rowClass] ?? 0}',
      ].join(', ')}',
      'OPS $label lineup actions: inside unchanged groups '
          '${t.lineupsInsideGroups}, changing which groups exist '
          '${t.lineupsChangingGroups}',
      'OPS $label action kinds: ${_counted(t.actionKinds)}',
      if (t.differencesByField.isNotEmpty)
        'OPS $label read-back differences by field: '
            '${_counted(t.differencesByField)}',
      for (final refused in t.commitsRefused)
        'OPS $label refused ${refused.action}: ${refused.reason}',
      for (final gap in t.gaps) 'OPS $label gap ${gap.action}: ${gap.gap}',
      for (final lineup in t.lineups)
        if (lineup.shape case LineupGroupsChanged(:final before, :final after))
          'OPS $label lineup ${lineup.action}: groups ${before.length} -> '
              '${after.length}, ${before.difference(after).length} gone, '
              '${after.difference(before).length} new',
      for (final finding in t.findings) ...[
        if (finding.differences.isNotEmpty)
          'OPS $label save ${finding.save} read back unequal after '
              '[${finding.actions.join('; ')}]: '
              '${finding.differences.take(12).join('; ')}'
              '${finding.differences.length > 12 ? ' (+${finding.differences.length - 12})' : ''}',
        if (finding.realWrites.isNotEmpty)
          'OPS $label save ${finding.save} image wrote real rows after '
              '[${finding.actions.join('; ')}]: '
              '${finding.realWrites.take(8).join('; ')}',
      ],
    ];

Future<List<String>> actionOpsStep(
  ProviderContainer c, {
  required String label,
  required Map<String, Object?> expected,
}) async {
  final journal = _journal(c) ??
      (throw StoreStepFailed(['this run does not journal action ops']));
  if (c.read(shadowProvider.notifier).mode case Mirroring(:final mirror)
      when mirror.phase is MirrorFollowing) {
    await saveOpenLocalStrategy(c, mirror);
    await mirror.drained().timeout(const Duration(seconds: 60));
  }
  final lines = actionOpsLines(label, journal.tally);
  final counts = opsCounts(journal.tally);
  final problems = [
    for (final MapEntry(:key, :value) in expected.entries)
      if (counts[key] != value) '$key is ${counts[key]}, expected $value',
  ];
  if (problems.isNotEmpty) throw StoreStepFailed([...lines, ...problems]);
  return lines;
}

Future<void> saveOpenLocalStrategy(
    ProviderContainer c, StoreMirror mirror) async {
  if (mirror.actions == null) return;
  final strategy = c.read(strategyProvider);
  final id = strategy.strategyId;
  if (id == null || strategy.source != StrategySource.local) return;
  await c.read(strategyProvider.notifier).forceSaveNow(id);
  await mirror.drained();
}

List<String> actionOpsEndLines(StoreMirror mirror) => switch (mirror.actions) {
      final journal? => actionOpsLines('run', journal.tally),
      null => const [],
    };
