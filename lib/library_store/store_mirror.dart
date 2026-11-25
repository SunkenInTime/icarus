import 'dart:async';

import 'package:icarus/library_store/action_journal.dart';
import 'package:icarus/library_store/canvas_units.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/hive_reads.dart';
import 'package:icarus/library_store/library_box_writes.dart';
import 'package:icarus/library_store/shadow_copy.dart';
import 'package:icarus/library_store/store_check.dart';
import 'package:icarus/library_store/strategy_image.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

sealed class MirrorStop {
  const MirrorStop();
}

final class MirrorStoreStopped extends MirrorStop {
  const MirrorStoreStopped(this.stop);

  final CopyStop stop;

  @override
  String toString() => '$stop';
}

final class MirrorFaulted extends MirrorStop {
  const MirrorFaulted(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;

  @override
  String toString() => 'the mirror met an error: $error';
}

sealed class MirrorPhase {
  const MirrorPhase();
}

final class MirrorWaitingForStore extends MirrorPhase {
  const MirrorWaitingForStore();
}

final class MirrorFollowing extends MirrorPhase {
  const MirrorFollowing(this.store, this.holds);

  final LibraryStore store;
  final StoreHolds holds;
}

final class MirrorHeld extends MirrorPhase {
  const MirrorHeld();
}

final class MirrorStopped extends MirrorPhase {
  const MirrorStopped(this.stop);

  final MirrorStop stop;
}

final class MirrorWrote {
  const MirrorWrote({required this.strategies, required this.folders});

  static const nothing =
      MirrorWrote(strategies: <String>{}, folders: <String>{});

  final Set<String> strategies;
  final Set<String> folders;
}

final class StoreMirror extends LocalLibraryFollower {
  StoreMirror({
    required this.reads,
    required this.betweenAnimations,
    this.actions,
  });

  final HiveReads reads;
  final Future<void> Function() betweenAnimations;
  final ActionJournal? actions;
  final _journaled = <LibraryTouch>{};
  final _failed = <LibraryTouch>{};

  MirrorPhase _phase = const MirrorWaitingForStore();
  final _strategies = <String>{};
  final _folders = <String>{};
  final _refusedStrategies = <String, CopyRefusal>{};
  final _readsBackDifferently = <String, String>{};
  final _images = StrategyImages();
  final _refusedFolders = <String, CopyRefusal>{};
  var _working = false;
  var _batches = 0;
  var _noticed = 0;
  var _idle = Completer<void>()..complete();
  var _strategiesInFlight = const <String>{};
  var _foldersInFlight = const <String>{};
  final _updates = StreamController<MirrorWrote>.broadcast(sync: true);

  MirrorPhase get phase => _phase;

  Stream<MirrorWrote> get updates => _updates.stream;

  void _phaseIs(MirrorPhase phase) {
    _phase = phase;
    _updates.add(MirrorWrote.nothing);
  }

  int get batches => _batches;

  Map<String, CopyRefusal> get refusedStrategies =>
      Map.unmodifiable(_refusedStrategies);

  Map<String, CopyRefusal> get refusedFolders =>
      Map.unmodifiable(_refusedFolders);

  int get pending => _strategies.length + _folders.length;

  @override
  void onWriting(LibraryTouch touch) {
    _noticed++;
    reads.writing(touch);
    if (_phase is MirrorFollowing && (actions?.takesSave(touch) ?? false)) {
      _journaled.add(touch);
      scheduleMicrotask(() {
        actions?.queueSavesAfterTheTurn();
        _kick();
      });
    }
  }

  @override
  void onWriteFailed(LibraryTouch touch) {
    if (_journaled.contains(touch)) _failed.add(touch);
  }

  @override
  void onAnswered(LibraryTouch touch) {
    _noticed++;
    reads.answered(touch);
    if (_journaled.remove(touch)) {
      actions!.answered(touch, written: !_failed.remove(touch));
    } else {
      _strategies.addAll(touch.strategies
          .where(reads.names.strategies.namesById)
          .where((id) => !_handedOff(id)));
    }
    _folders.addAll(touch.folders.where(reads.names.folders.namesById));
    _kick();
  }

  Future<int> releaseTakenUp() async {
    final journal = actions;
    if (journal == null) return 0;
    journal.source?.closeOut();
    if (_phase is! MirrorFollowing) return 0;
    await drained();
    final taken = journal.takenUp;
    for (final id in taken) {
      final hive = const LocalLibrary().storedStrategy(id);
      journal.release(id, hive == null ? null : cloneStrategy(hive));
    }
    _kick();
    await drained();
    return taken.length;
  }

  void unitOpened() => actions?.opened();

  void closedWithoutJudging(
    List<DeclaredAction> declared, {
    required String notJudged,
    required String discarded,
  }) =>
      actions?.closedWithoutJudging(
        declared,
        notJudged: notJudged,
        discarded: discarded,
      );

  void takeUp(
    String strategyId,
    StrategyData hive,
    StrategyData canvas,
    List<DeclaredAction> declared,
  ) {
    final journal = actions;
    if (journal == null) return;
    if (_phase is! MirrorFollowing) {
      journal.closedWithoutJudging(
        declared,
        notJudged: 'the mirror was not following yet',
        discarded: 'actions before the mirror was following',
      );
      return;
    }
    journal.takeUp(strategyId, hive, canvas, declared);
    _strategies.remove(strategyId);
    _kick();
  }

  void unit(
    String strategyId, {
    required UnitKind kind,
    required List<DeclaredAction> declared,
    required StrategyData? snapshot,
    required Set<String> pages,
    String? notJudged,
    int items = 0,
    Duration snapshotTime = Duration.zero,
  }) {
    final journal = actions;
    if (journal == null) return;
    if (_phase is! MirrorFollowing) {
      journal.closedWithoutJudging(
        declared,
        notJudged: 'the mirror was not following yet',
        discarded: 'actions before the mirror was following',
      );
      return;
    }
    journal.unit(
      strategyId,
      kind: kind,
      actions: declared,
      snapshot: snapshot,
      pages: pages,
      notJudged: notJudged,
      items: items,
      snapshotTime: snapshotTime,
    );
    _kick();
  }

  void release(String strategyId, StrategyData? hive) {
    final journal = actions;
    if (journal == null || _phase is! MirrorFollowing) return;
    journal.release(strategyId, hive);
    _kick();
  }

  void followerFaulted(String label, String fault) =>
      actions?.faulted(label, fault);

  bool _handedOff(String strategyId) => actions?.follows(strategyId) ?? false;

  @override
  void onFault(Object error, StackTrace stackTrace) =>
      _stop(MirrorFaulted(error, stackTrace));

  void _stop(MirrorStop stop) {
    _working = false;
    actions?.forget();
    _journaled.clear();
    _failed.clear();
    _phaseIs(MirrorStopped(stop));
    if (!_idle.isCompleted) _idle.complete();
  }

  Set<String> get strategiesNotKnownEqual => {
        ...?actions?.takenUp,
        ..._strategies,
        ..._strategiesInFlight,
        ...reads.strategiesBeingWritten,
        ..._refusedStrategies.keys,
        ...reads.names.strategies.keptIds,
      };

  Map<String, String> get strategiesReadingBackDifferently =>
      Map.unmodifiable(_readsBackDifferently);

  Set<String> get foldersNotKnownEqual => {
        ..._folders,
        ..._foldersInFlight,
        ...reads.foldersBeingWritten,
        ..._refusedFolders.keys,
        ...reads.names.folders.keptIds,
      };

  Future<ShadowCopy> copyThenFollow(
    LibraryStore store, {
    required LibraryBoxWrites writes,
    void Function(int done, int total)? progress,
  }) async {
    _working = true;
    _idle = Completer<void>();
    final ShadowCopy copy;
    try {
      copy = await copyHiveIntoStore(
        reads,
        store,
        images: _images,
        writes: writes,
        breathe: betweenAnimations,
        progress: progress,
      );
    } on Object catch (error, stackTrace) {
      _stop(MirrorFaulted(error, stackTrace));
      return ShadowCopyFaulted(error, stackTrace);
    }
    _record(copy, const {}, const {});
    _working = false;
    switch ((copy, store.library)) {
      case (ShadowCopyStopped(:final stop), _):
        _stop(MirrorStoreStopped(stop));
      case (ShadowCopyFaulted(:final error, :final stackTrace), _):
        _stop(MirrorFaulted(error, stackTrace));
      case (_, LibraryShut(:final failure)):
        _stop(MirrorStoreStopped(StoreDidNotRead(failure)));
      case (
          ShadowCopyFinished() || ShadowCopyRaced(),
          LibraryOpen(:final list)
        ):
        _phaseIs(MirrorFollowing(store, StoreHolds.of(list)));
    }
    _kick();
    return copy;
  }

  void hold() {
    if (_phase case MirrorFollowing()) _phaseIs(const MirrorHeld());
  }

  Future<void> drained() => _idle.future;

  Future<StoreCheck> check(
    Future<StoreCheck> Function(HiveLibrary hive) compare,
  ) async {
    while (_working || _hasWork) {
      if (!_working) _kick();
      if (_idle.isCompleted) break;
      await _idle.future;
    }
    _working = true;
    if (_idle.isCompleted) _idle = Completer<void>();
    final before = _noticed;
    final snapshot = reads.library();
    final StoreCheck checked;
    try {
      checked = await compare(snapshot.library);
    } finally {
      _working = false;
      _kick();
    }
    final changes = snapshot.writes + _noticed - before;
    return changes == 0 ? checked : StoreChangedDuringCheck(checked, changes);
  }

  bool get _hasWork =>
      _phase is MirrorFollowing &&
      ((actions?.hasDue ?? false) ||
          _strategies
              .any((id) => !reads.strategyWriting(id) && !_handedOff(id)) ||
          _folders.any((id) => !reads.folderWriting(id)));

  ({Set<String> strategies, Set<String> folders}) _choose() {
    _strategies.removeWhere(_handedOff);
    return (
      strategies: {
        for (final id in {..._strategies, ..._refusedStrategies.keys})
          if (!reads.strategyWriting(id) && !_handedOff(id)) id,
      },
      folders: {
        for (final id in {..._folders, ..._refusedFolders.keys})
          if (!reads.folderWriting(id)) id,
      },
    );
  }

  void _kick() {
    if (_working) return;
    switch (_phase) {
      case MirrorFollowing() when _hasWork:
        _working = true;
        if (_idle.isCompleted) _idle = Completer<void>();
        Timer.run(_pump);
      case MirrorFollowing() || MirrorHeld() || MirrorStopped():
        if (!_idle.isCompleted) _idle.complete();
      case MirrorWaitingForStore():
        break;
    }
  }

  Future<void> _pump() async {
    try {
      await _batchesWhileDue();
    } on Object catch (error, stackTrace) {
      _stop(MirrorFaulted(error, stackTrace));
      return;
    }
    _working = false;
    _kick();
  }

  Future<void> _batchesWhileDue() async {
    while (_hasWork) {
      await betweenAnimations();
      final LibraryStore store;
      final StoreHolds holds;
      switch (_phase) {
        case MirrorFollowing(store: final following, holds: final held):
          store = following;
          holds = held;
        case MirrorWaitingForStore() || MirrorHeld() || MirrorStopped():
          return;
      }
      if (actions case final journal? when journal.hasDue) {
        switch (await journal.runDue(store)) {
          case JournalContinues():
            break;
          case JournalStopped(:final stop):
            _stop(MirrorStoreStopped(stop));
            return;
          case JournalPut(
              :final strategyId,
              :final image,
              :final removeFirst,
            ):
            if (removeFirst) {
              switch (await store.editLibrary([RemoveStrategy(strategyId)])) {
                case NotSaved(:final failure):
                  _stop(MirrorStoreStopped(StoreDidNotSave(failure)));
                  return;
                case SaveInDoubt(:final failure):
                  _stop(MirrorStoreStopped(StoreSaveInDoubt(failure)));
                  return;
                case Saved() || NothingToSave() || Refused():
                  holds.strategies.remove(strategyId);
              }
            }
            final written = await mirrorImage(store, holds, strategyId, image);
            _batches++;
            if (written case ShadowCopyStopped(:final stop)) {
              _stop(MirrorStoreStopped(stop));
            }
            _record(written, {strategyId}, const {});
            if (written is ShadowCopyStopped) return;
        }
        continue;
      }
      final (:strategies, :folders) = _choose();
      _strategies.removeAll(strategies);
      _folders.removeAll(folders);
      _strategiesInFlight = strategies;
      _foldersInFlight = folders;
      final ShadowCopy batch;
      try {
        batch = await mirrorIds(
          reads,
          store,
          holds,
          images: _images,
          strategies: strategies,
          folders: folders,
          handedOff: _handedOff,
          breathe: betweenAnimations,
        );
      } finally {
        _strategiesInFlight = const {};
        _foldersInFlight = const {};
      }
      _batches++;
      if (batch case ShadowCopyStopped(:final stop)) {
        _stop(MirrorStoreStopped(stop));
      }
      _record(batch, strategies, folders);
      if (batch is ShadowCopyStopped) return;
    }
  }

  void _record(ShadowCopy copy, Set<String> strategies, Set<String> folders) {
    final strategiesWaiting = {
      for (final strategy in copy.strategies)
        if (strategy case StrategyWaitsForHive(:final strategyId)) strategyId,
    };
    final foldersWaiting = {
      for (final folder in copy.folders)
        if (folder case FolderWaitsForHive(:final folderId)) folderId,
    };
    _refusedStrategies.removeWhere(
      (id, _) => strategies.contains(id) && !strategiesWaiting.contains(id),
    );
    _refusedFolders.removeWhere(
      (id, _) => folders.contains(id) && !foldersWaiting.contains(id),
    );
    for (final strategy in copy.strategies) {
      switch (strategy) {
        case StrategyWaitsForHive():
          break;
        case StrategyNotMirrored(:final strategyId, :final reason):
          _refusedStrategies[strategyId] = reason;
          _readsBackDifferently.remove(strategyId);
        case StrategyCopied(:final strategyId, :final readBack) ||
              StrategyUnchanged(:final strategyId, :final readBack) ||
              StrategyTookHiveVersion(:final strategyId, :final readBack):
          _refusedStrategies.remove(strategyId);
          switch (readBack) {
            case ReadsBackEqual():
              _readsBackDifferently.remove(strategyId);
            case ReadsBackDifferently(:final words):
              _readsBackDifferently[strategyId] = words;
          }
        case StrategyRemovedWithHive(:final strategyId):
          _refusedStrategies.remove(strategyId);
          _readsBackDifferently.remove(strategyId);
          _images.forget(strategyId);
      }
    }
    for (final folder in copy.folders) {
      switch (folder) {
        case FolderWaitsForHive():
          break;
        case FolderNotCopied(:final folderId, :final reason):
          _refusedFolders[folderId] = reason;
        case FolderCopied(:final folderId) ||
              FolderUnchanged(:final folderId) ||
              FolderRemovedWithHive(:final folderId):
          _refusedFolders.remove(folderId);
      }
    }
    _updates.add(MirrorWrote(strategies: strategies, folders: folders));
  }
}
