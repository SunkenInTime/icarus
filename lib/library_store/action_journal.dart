import 'dart:async';
import 'dart:collection';

import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/action_ops.dart';
import 'package:icarus/library_store/canvas_changes.dart';
import 'package:icarus/library_store/canvas_units.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/shadow_copy.dart';
import 'package:icarus/library_store/stored_strategy.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

final class DeclaredAction {
  const DeclaredAction(this.label, this.changes);

  final String label;
  final List<CanvasChange> changes;
}

enum UnitKind { user, silent, load }

sealed class _Job {
  const _Job(this.strategyId);

  final String strategyId;
}

final class _TakeUpJob extends _Job {
  const _TakeUpJob(super.strategyId, this.hive, this.canvas);

  final StrategyData hive;
  final StrategyData canvas;
}

final class _UnitJob extends _Job {
  const _UnitJob(
    super.strategyId, {
    required this.kind,
    required this.actions,
    required this.snapshot,
    required this.pages,
    required this.notJudged,
    required this.items,
    required this.snapshotTime,
  });

  final UnitKind kind;
  final List<DeclaredAction> actions;
  final StrategyData? snapshot;
  final Set<String> pages;
  final String? notJudged;
  final int items;
  final Duration snapshotTime;
}

final class _ReleaseJob extends _Job {
  const _ReleaseJob(super.strategyId, this.hive);

  final StrategyData? hive;
}

enum _SaveState { writing, written, failed }

final class _SaveJob extends _Job {
  _SaveJob(this.touch, super.strategyId, this.image)
      : state = _SaveState.writing;

  final LibraryTouch touch;
  final StrategyToRows image;
  _SaveState state;
}

StrategyToRows rowsOf(StrategyData strategy) =>
    strategyToRows(strategyAsHiveHoldsIt(strategy));

enum UnitOutcome { coveredAndCorrect, changedWithoutAction, opsWrong }

final class UnitFinding {
  const UnitFinding({
    required this.number,
    required this.kind,
    required this.uncovered,
    required this.wrong,
    required this.gaps,
  });

  final int number;
  final String kind;
  final List<String> uncovered;
  final List<String> wrong;
  final List<String> gaps;
}

final class KindCounts {
  var judged = 0;
  var coveredAndCorrect = 0;
  var changedWithoutAction = 0;
  var opsWrong = 0;
  final notJudged = <String, int>{};
}

final class UnitCost {
  const UnitCost(this.items, this.snapshot, this.replay, this.compare);

  final int items;
  final Duration snapshot;
  final Duration replay;
  final Duration compare;
}

final class HiveSaveFinding {
  const HiveSaveFinding(this.save, this.differences);

  final int save;
  final List<String> differences;
}

final class ActionOpsTally {
  var unitsOpened = 0;
  var unitsWithNoChange = 0;
  var coveredAndCorrect = 0;
  var changedWithoutAction = 0;
  var opsWrong = 0;
  var bothChecksFailed = 0;
  final notJudged = <String, int>{};
  final byKind = <String, KindCounts>{};
  final findings = <UnitFinding>[];
  var actions = 0;
  var commits = 0;
  var opsCommitted = 0;
  final commitsRefused = <String>[];
  var takenUp = 0;
  var released = 0;
  var releasesThatPutHiveBack = 0;
  var repairsFromCanvas = 0;
  final followerFaults = <String>[];
  final costs = <UnitCost>[];
  var hiveSaves = 0;
  var hiveSavesFailed = 0;
  var hiveSavesEqualToStore = 0;
  var hiveSavesDifferent = 0;
  final hiveFindings = <HiveSaveFinding>[];
  final hiveDifferencesByField = <String, int>{};

  int get unitsJudged => coveredAndCorrect + changedOrWrong;

  int get changedOrWrong => changedWithoutAction + opsWrong - bothChecksFailed;

  int get unitsNotJudged => notJudged.values.fold(0, (a, b) => a + b);

  bool get addsUp => unitsOpened == unitsJudged + unitsNotJudged;
}

final class ActionJournal {
  ActionJournal({StrategyData? Function(String id)? hiveNow})
      : _hiveNow = hiveNow ?? const LocalLibrary().storedStrategy;

  final StrategyData? Function(String id) _hiveNow;
  final _jobs = Queue<_Job>();
  final _takenUp = <String>{};
  final _previous = <String, StrategyData>{};
  final tally = ActionOpsTally();
  List<StrategyOp> Function(String label, List<StrategyOp> ops) alterOps =
      _asBuilt;
  void Function(String strategyId) onHiveWrite = _nobody;

  static List<StrategyOp> _asBuilt(String label, List<StrategyOp> ops) => ops;

  static void _nobody(String strategyId) {}

  bool follows(String strategyId) => _takenUp.contains(strategyId);

  Set<String> get takenUp => Set.unmodifiable(_takenUp);

  bool get hasDue => switch (_jobs.firstOrNull) {
        null => false,
        final _SaveJob save => save.state != _SaveState.writing,
        _ => true,
      };

  StrategyData? hiveNow(String strategyId) => _hiveNow(strategyId);

  void takeUp(String strategyId, StrategyData hive, StrategyData canvas) {
    _takenUp.add(strategyId);
    _jobs.add(_TakeUpJob(strategyId, hive, canvas));
  }

  void unit(
    String strategyId, {
    required UnitKind kind,
    required List<DeclaredAction> actions,
    required StrategyData? snapshot,
    required Set<String> pages,
    String? notJudged,
    int items = 0,
    Duration snapshotTime = Duration.zero,
  }) {
    tally.actions += actions.length;
    _jobs.add(_UnitJob(
      strategyId,
      kind: kind,
      actions: actions,
      snapshot: snapshot,
      pages: pages,
      notJudged: notJudged,
      items: items,
      snapshotTime: snapshotTime,
    ));
  }

  void release(String strategyId, StrategyData? hive) {
    _takenUp.remove(strategyId);
    _jobs.add(_ReleaseJob(strategyId, hive));
  }

  bool takesSave(LibraryTouch touch) {
    final saved = touch.wrote;
    if (saved == null) return false;
    if (!_takenUp.contains(saved.id)) return false;
    _jobs.add(_SaveJob(touch, saved.id, rowsOf(saved)));
    onHiveWrite(saved.id);
    return true;
  }

  void answered(LibraryTouch touch, {required bool written}) {
    for (final job in _jobs) {
      if (job is _SaveJob &&
          identical(job.touch, touch) &&
          job.state == _SaveState.writing) {
        job.state = written ? _SaveState.written : _SaveState.failed;
      }
    }
  }

  void faulted(String label, String fault) {
    tally.followerFaults.add('$label: $fault');
  }

  void forget() {
    _jobs.clear();
    _takenUp.clear();
    _previous.clear();
  }

  Future<JournalStep> runDue(LibraryStore store) async {
    final job = _jobs.removeFirst();
    return switch (job) {
      final _TakeUpJob takeUp => await _runTakeUp(store, takeUp),
      final _UnitJob unit => await _runUnit(store, unit),
      final _ReleaseJob release => await _runRelease(store, release),
      final _SaveJob save => await _runSave(store, save),
    };
  }

  Future<JournalStep> _runTakeUp(LibraryStore store, _TakeUpJob job) async {
    tally.takenUp += 1;
    _previous[job.strategyId] = job.canvas;
    return JournalPut(
      job.strategyId,
      rowsOf(job.hive),
      removeFirst: await _holdsWhatAnImageCannotDrop(store, job.strategyId),
    );
  }

  Future<JournalStep> _runRelease(LibraryStore store, _ReleaseJob job) async {
    tally.released += 1;
    _previous.remove(job.strategyId);
    final hive = job.hive;
    if (hive == null) return const JournalContinues();
    final read = await _readStore(store, job.strategyId);
    final differences = read == null
        ? null
        : differencesOn(hive, read, {for (final page in hive.pages) page.id});
    if (differences != null && differences.isEmpty) {
      return const JournalContinues();
    }
    tally.releasesThatPutHiveBack += 1;
    return JournalPut(
      job.strategyId,
      rowsOf(hive),
      removeFirst: await _holdsWhatAnImageCannotDrop(store, job.strategyId),
    );
  }

  void _notJudged(String kind, String reason) {
    tally.unitsOpened += 1;
    tally.notJudged.update(reason, (n) => n + 1, ifAbsent: () => 1);
    final counts = tally.byKind.putIfAbsent(kind, KindCounts.new);
    counts.notJudged.update(reason, (n) => n + 1, ifAbsent: () => 1);
  }

  String _kindOf(_UnitJob job) {
    if (job.kind == UnitKind.load) return 'page loaded';
    final labels = <String>[];
    for (final action in job.actions) {
      if (!labels.contains(action.label)) labels.add(action.label);
    }
    return labels.isEmpty ? 'no action' : labels.join(' + ');
  }

  Future<JournalStep> _runUnit(LibraryStore store, _UnitJob job) async {
    final id = job.strategyId;
    final kind = _kindOf(job);
    final snapshot = job.snapshot;
    if (snapshot == null) {
      _notJudged(kind, job.notJudged ?? 'nothing captured');
      return const JournalContinues();
    }
    if (job.kind == UnitKind.load) {
      _previous[id] = snapshot;
      _notJudged(kind, 'a page loading');
      return const JournalContinues();
    }
    final previous = _previous[id];
    if (previous == null) {
      _previous[id] = snapshot;
      _notJudged(kind, 'no earlier snapshot');
      return const JournalContinues();
    }

    final gaps = <String>[];
    var refused = false;
    for (final action in job.actions) {
      if (action.changes.isEmpty) continue;
      final builder = await OpsBuilder.read(store, id);
      if (builder == null) {
        gaps.add('${action.label}: the store has no readable strategy');
        continue;
      }
      final built = await builder.build(action.changes);
      for (final gap in built.gaps) {
        gaps.add('${action.label}: $gap');
      }
      final ops = alterOps(action.label, built.ops);
      if (ops.isEmpty) continue;
      tally.commits += 1;
      switch (await store.commitAll(id, ops)) {
        case Saved():
          tally.opsCommitted += ops.length;
        case NothingToSave():
          break;
        case Refused(:final reason):
          refused = true;
          tally.commitsRefused.add('${action.label}: $reason');
        case NotSaved(:final failure):
          return JournalStopped(StoreDidNotSave(failure));
        case SaveInDoubt(:final failure):
          return JournalStopped(StoreSaveInDoubt(failure));
      }
    }

    final replayClock = Stopwatch()..start();
    final declared = [
      for (final action in job.actions) ...action.changes,
    ];
    final replayed = replayDeclared(previous, declared);
    final replayTime = replayClock.elapsed;
    final pages = {...job.pages, ...pagesNamedBy(declared)};

    final compareClock = Stopwatch()..start();
    final read = await _readStore(store, id);
    final uncovered = differencesOn(replayed.strategy, snapshot, pages);
    final wrong =
        read == null ? null : differencesOn(replayed.strategy, read, pages);
    final behind = read == null ? null : differencesOn(snapshot, read, pages);
    tally.costs.add(UnitCost(
      job.items,
      job.snapshotTime,
      replayTime,
      compareClock.elapsed,
    ));
    _previous[id] = snapshot;

    Future<JournalStep> repair() async => JournalPut(
          id,
          rowsOf(snapshot),
          removeFirst: await _holdsWhatAnImageCannotDrop(store, id),
        );

    if (read == null || uncovered == null || wrong == null || behind == null) {
      _notJudged(kind, 'the store could not be read');
      return repair();
    }
    final uncoveredLines = [
      for (final d in uncovered) '$d',
      for (final s in replayed.stale) '$s',
    ];
    final wrongLines = [for (final d in wrong) '$d'];
    if (job.actions.isEmpty &&
        uncoveredLines.isEmpty &&
        wrongLines.isEmpty &&
        behind.isEmpty) {
      tally.unitsWithNoChange += 1;
      return const JournalContinues();
    }
    if (refused) {
      _notJudged(kind, 'a commit was refused');
      return behind.isEmpty
          ? const JournalContinues()
          : _repaired(await repair());
    }

    tally.unitsOpened += 1;
    final counts = tally.byKind.putIfAbsent(kind, KindCounts.new)..judged += 1;
    if (uncoveredLines.isEmpty && wrongLines.isEmpty) {
      tally.coveredAndCorrect += 1;
      counts.coveredAndCorrect += 1;
    } else {
      if (uncoveredLines.isNotEmpty) {
        tally.changedWithoutAction += 1;
        counts.changedWithoutAction += 1;
      }
      if (wrongLines.isNotEmpty) {
        tally.opsWrong += 1;
        counts.opsWrong += 1;
      }
      if (uncoveredLines.isNotEmpty && wrongLines.isNotEmpty) {
        tally.bothChecksFailed += 1;
      }
      tally.findings.add(UnitFinding(
        number: tally.unitsOpened,
        kind: kind,
        uncovered: uncoveredLines,
        wrong: wrongLines,
        gaps: gaps,
      ));
    }
    return behind.isEmpty
        ? const JournalContinues()
        : _repaired(await repair());
  }

  JournalStep _repaired(JournalStep step) {
    tally.repairsFromCanvas += 1;
    return step;
  }

  Future<JournalStep> _runSave(LibraryStore store, _SaveJob job) async {
    if (job.state == _SaveState.failed) {
      tally.hiveSavesFailed += 1;
      return const JournalContinues();
    }
    tally.hiveSaves += 1;
    final saved = switch (job.image) {
      StrategyRowsMade(:final rows) => switch (strategyFromRows(rows)) {
          StrategyDataMade(:final strategy) => strategy,
          StrategyDataRefused() => null,
        },
      StrategyRowsRefused() => null,
    };
    final read = await _readStore(store, job.strategyId);
    if (saved == null || read == null) return const JournalContinues();
    final differences = differencesOn(
      read,
      saved,
      {for (final page in saved.pages) page.id},
    );
    if (differences == null || differences.isEmpty) {
      tally.hiveSavesEqualToStore += 1;
      return const JournalContinues();
    }
    tally.hiveSavesDifferent += 1;
    for (final d in differences) {
      tally.hiveDifferencesByField.update(
        '${d.what} ${d.field}',
        (n) => n + 1,
        ifAbsent: () => 1,
      );
    }
    tally.hiveFindings.add(HiveSaveFinding(
      tally.hiveSaves,
      [for (final d in differences) '$d'],
    ));
    return const JournalContinues();
  }

  Future<StrategyData?> _readStore(LibraryStore store, String id) async =>
      switch (await readStoredRows(store, id)) {
        StoredRowsRead(:final rows) => switch (strategyFromRows(rows)) {
            StrategyDataMade(:final strategy) => strategy,
            StrategyDataRefused() => null,
          },
        StoredRowsNot() => null,
      };

  static Future<bool> _holdsWhatAnImageCannotDrop(
    LibraryStore store,
    String id,
  ) async =>
      switch (await readStoredRows(store, id)) {
        StoredRowsRead(:final rows) =>
          rows.pages.any((page) => page is TrashedPage) ||
              rows.elements.any((row) => row is DeletedElement) ||
              rows.lineupGroups.any((row) => row is DeletedLineupGroup),
        StoredRowsNot() => false,
      };
}

sealed class JournalStep {
  const JournalStep();
}

final class JournalContinues extends JournalStep {
  const JournalContinues();
}

final class JournalPut extends JournalStep {
  const JournalPut(
    this.strategyId,
    this.image, {
    required this.removeFirst,
  });

  final String strategyId;
  final StrategyToRows image;
  final bool removeFirst;
}

final class JournalStopped extends JournalStep {
  const JournalStopped(this.stop);

  final CopyStop stop;
}
