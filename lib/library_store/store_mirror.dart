import 'dart:async';

import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/hive_reads.dart';
import 'package:icarus/library_store/library_box_writes.dart';
import 'package:icarus/library_store/shadow_copy.dart';
import 'package:icarus/library_store/store_check.dart';
import 'package:icarus/strategy/local_library.dart';
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
  StoreMirror({required this.reads, required this.betweenAnimations});

  final HiveReads reads;
  final Future<void> Function() betweenAnimations;

  MirrorPhase _phase = const MirrorWaitingForStore();
  final _strategies = <String>{};
  final _folders = <String>{};
  final _refusedStrategies = <String, CopyRefusal>{};
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
  }

  @override
  void onAnswered(LibraryTouch touch) {
    _noticed++;
    reads.answered(touch);
    _strategies
        .addAll(touch.strategies.where(reads.names.strategies.namesById));
    _folders.addAll(touch.folders.where(reads.names.folders.namesById));
    _kick();
  }

  @override
  void onFault(Object error, StackTrace stackTrace) =>
      _stop(MirrorFaulted(error, stackTrace));

  void _stop(MirrorStop stop) {
    _working = false;
    _phaseIs(MirrorStopped(stop));
    if (!_idle.isCompleted) _idle.complete();
  }

  Set<String> get strategiesNotKnownEqual => {
        ..._strategies,
        ..._strategiesInFlight,
        ...reads.strategiesBeingWritten,
        ..._refusedStrategies.keys,
        ...reads.names.strategies.keptIds,
      };

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
      (_strategies.any((id) => !reads.strategyWriting(id)) ||
          _folders.any((id) => !reads.folderWriting(id)));

  ({Set<String> strategies, Set<String> folders}) _choose() => (
        strategies: {
          for (final id in {..._strategies, ..._refusedStrategies.keys})
            if (!reads.strategyWriting(id)) id,
        },
        folders: {
          for (final id in {..._folders, ..._refusedFolders.keys})
            if (!reads.folderWriting(id)) id,
        },
      );

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
          strategies: strategies,
          folders: folders,
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
        case StrategyCopied(:final strategyId) ||
              StrategyUnchanged(:final strategyId) ||
              StrategyTookHiveVersion(:final strategyId) ||
              StrategyRemovedWithHive(:final strategyId):
          _refusedStrategies.remove(strategyId);
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
