import 'dart:async';
import 'dart:collection';

import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/action_ops.dart';
import 'package:icarus/library_store/canvas_changes.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/ops_verdict.dart';
import 'package:icarus/library_store/shadow_copy.dart';
import 'package:icarus/library_store/stored_strategy.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

sealed class _Job {
  const _Job(this.strategyId);

  final String strategyId;
}

final class _ActionJob extends _Job {
  _ActionJob(super.strategyId, this.label, this.changes);

  final String label;
  final Future<List<CanvasChange>> changes;
}

final class _SaveJob extends _Job {
  _SaveJob(this.touch, this.saved, {this.compares = true})
      : answered = touch == null,
        super(saved.id);

  final LibraryTouch? touch;
  final StrategyData saved;
  final bool compares;
  bool answered;
}

final class SaveFinding {
  SaveFinding({
    required this.save,
    required this.differences,
    required this.actions,
    required this.realWrites,
  });

  final int save;
  final List<ReadBackDifference> differences;
  final List<String> actions;
  final List<ImageRowWrite> realWrites;
}

final class CommitRefusedFinding {
  const CommitRefusedFinding(this.action, this.reason);

  final String action;
  final String reason;
}

final class GapFinding {
  const GapFinding(this.action, this.gap);

  final String action;
  final OpGap gap;
}

final class LineupFinding {
  const LineupFinding(this.action, this.shape);

  final String action;
  final LineupShape shape;
}

final class ActionOpsTally {
  var actions = 0;
  var actionsWithOps = 0;
  var commits = 0;
  var opsCommitted = 0;
  var commitsWithNothingToSave = 0;
  final commitsRefused = <CommitRefusedFinding>[];
  final gaps = <GapFinding>[];
  final lineups = <LineupFinding>[];
  final actionKinds = <String, int>{};
  var saves = 0;
  var savesNotInStore = 0;
  var savesNotRead = 0;
  var readBackEqual = 0;
  var readBackUnequal = 0;
  var imageWroteNothing = 0;
  var imageWroteRows = 0;
  final rowsByClass = <ImageRowClass, int>{};
  var trashedPagesRemoved = 0;
  var repairedAtEnd = 0;
  var actionsAfterLastSave = 0;
  final findings = <SaveFinding>[];
  final differencesByField = <String, int>{};

  int get lineupsInsideGroups =>
      lineups.where((l) => l.shape is LineupsInsideGroups).length;

  int get lineupsChangingGroups =>
      lineups.where((l) => l.shape is LineupGroupsChanged).length;
}

final class ActionJournal {
  final _jobs = Queue<_Job>();
  final _following = <String>{};
  final _sinceSave = <String, List<String>>{};
  final tally = ActionOpsTally();

  bool follows(String strategyId) => _following.contains(strategyId);

  bool get hasDue => switch (_jobs.firstOrNull) {
        null => false,
        final _SaveJob save => save.answered,
        _ActionJob() => true,
      };

  void action(
    String strategyId,
    String label,
    Future<List<CanvasChange>> changes,
  ) {
    _following.add(strategyId);
    _jobs.add(_ActionJob(strategyId, label, changes));
    tally
      ..actions += 1
      ..actionKinds.update(label, (count) => count + 1, ifAbsent: () => 1);
  }

  bool takesSave(LibraryTouch touch) {
    final saved = touch.wrote;
    if (saved == null || !_following.contains(saved.id)) return false;
    _jobs.add(_SaveJob(touch, saved));
    return true;
  }

  void answered(LibraryTouch touch) {
    for (final job in _jobs) {
      if (job is _SaveJob && identical(job.touch, touch)) job.answered = true;
    }
  }

  void forget() => _jobs.clear();

  Set<String> get unsaved => {
        for (final MapEntry(:key, :value) in _sinceSave.entries)
          if (value.isNotEmpty) key,
      };

  void repair(StrategyData current) {
    tally
      ..repairedAtEnd += 1
      ..actionsAfterLastSave += _sinceSave.remove(current.id)?.length ?? 0;
    _jobs.add(_SaveJob(null, current, compares: false));
  }

  Future<JournalStep> runDue(LibraryStore store) async {
    final job = _jobs.removeFirst();
    return switch (job) {
      final _ActionJob action => await _runAction(store, action),
      final _SaveJob save => await _runSave(store, save),
    };
  }

  Future<JournalStep> _runAction(LibraryStore store, _ActionJob job) async {
    (_sinceSave[job.strategyId] ??= []).add(job.label);
    final changes = await job.changes;
    if (changes.isEmpty) return const JournalContinues();
    final builder = await OpsBuilder.read(store, job.strategyId);
    if (builder == null) {
      tally.gaps.add(GapFinding(
        job.label,
        PageNotInStore(job.strategyId, 'strategy of'),
      ));
      return const JournalContinues();
    }
    final built = await builder.build(changes);
    for (final gap in built.gaps) {
      tally.gaps.add(GapFinding(job.label, gap));
    }
    for (final shape in built.lineupShapes) {
      tally.lineups.add(LineupFinding(job.label, shape));
    }
    if (built.ops.isEmpty) return const JournalContinues();
    tally
      ..actionsWithOps += 1
      ..commits += 1;
    switch (await store.commitAll(job.strategyId, built.ops)) {
      case Saved():
        tally.opsCommitted += built.ops.length;
      case NothingToSave():
        tally.commitsWithNothingToSave += 1;
      case Refused(:final reason):
        tally.commitsRefused.add(CommitRefusedFinding(job.label, '$reason'));
      case NotSaved(:final failure):
        return JournalStopped(StoreDidNotSave(failure));
      case SaveInDoubt(:final failure):
        return JournalStopped(StoreSaveInDoubt(failure));
    }
    return const JournalContinues();
  }

  Future<JournalStep> _runSave(LibraryStore store, _SaveJob job) async {
    final saved = strategyAsHiveHoldsIt(job.saved);
    final image = strategyToRows(saved);
    var trashed = false;
    if (!job.compares) {
      if (await readStoredRows(store, job.strategyId)
          case StoredRowsRead(:final rows)) {
        trashed = rows.pages.any((page) => page is TrashedPage);
      }
      return JournalSaved(job.strategyId, image, removeFirst: trashed);
    }
    final actions = _sinceSave.remove(job.strategyId) ?? const [];
    tally.saves += 1;
    switch (await readStoredRows(store, job.strategyId)) {
      case StoredRowsRead(:final rows):
        _compare(saved, image, rows, actions);
        trashed = rows.pages.any((page) => page is TrashedPage);
      case StoredRowsNot(stored: StoredMissing()):
        tally.savesNotInStore += 1;
      case StoredRowsNot():
        tally.savesNotRead += 1;
    }
    if (trashed) tally.trashedPagesRemoved += 1;
    return JournalSaved(job.strategyId, image, removeFirst: trashed);
  }

  void _compare(
    StrategyData saved,
    StrategyToRows image,
    StrategyRowSet stored,
    List<String> actions,
  ) {
    final StrategyData read;
    switch (strategyFromRows(stored)) {
      case StrategyDataMade(:final strategy):
        read = strategy;
      case StrategyDataRefused():
        tally.savesNotRead += 1;
        return;
    }
    final List<ReadBackDifference> differences;
    final List<ImageRowWrite> writes;
    switch (image) {
      case StrategyRowsMade(:final rows):
        final expected = switch (strategyFromRows(rows)) {
          StrategyDataMade(:final strategy) => strategy,
          StrategyDataRefused() => saved,
        };
        differences = readBackDifferences(expected, read);
        writes = imageRowWrites(rows, stored, saved: saved);
      case StrategyRowsRefused():
        tally.savesNotRead += 1;
        return;
    }
    if (differences.isEmpty) {
      tally.readBackEqual += 1;
    } else {
      tally.readBackUnequal += 1;
      for (final difference in differences) {
        tally.differencesByField.update(
          '${difference.what} ${difference.field}',
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
    }
    if (writes.isEmpty) {
      tally.imageWroteNothing += 1;
    } else {
      tally.imageWroteRows += 1;
      for (final write in writes) {
        tally.rowsByClass
            .update(write.rowClass, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    final real = [
      for (final write in writes)
        if (write.rowClass == ImageRowClass.real) write,
    ];
    if (differences.isNotEmpty || real.isNotEmpty) {
      tally.findings.add(SaveFinding(
        save: tally.saves,
        differences: differences,
        actions:
            actions.length > 6 ? actions.sublist(actions.length - 6) : actions,
        realWrites: real,
      ));
    }
  }
}

sealed class JournalStep {
  const JournalStep();
}

final class JournalContinues extends JournalStep {
  const JournalContinues();
}

final class JournalSaved extends JournalStep {
  const JournalSaved(this.strategyId, this.image, {required this.removeFirst});

  final String strategyId;
  final StrategyToRows image;
  final bool removeFirst;
}

final class JournalStopped extends JournalStep {
  const JournalStopped(this.stop);

  final CopyStop stop;
}
