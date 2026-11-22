import 'dart:async';

import 'package:icarus/library_store/hive_library.dart';
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

final class StoreMirror extends LocalLibraryFollower {
  StoreMirror({
    required this.readHive,
    required this.reads,
    required this.betweenAnimations,
  });

  final HiveLibrary Function() readHive;
  final LibraryReads reads;
  final Future<void> Function() betweenAnimations;

  MirrorPhase _phase = const MirrorWaitingForStore();
  final _strategies = <String>{};
  final _folders = <String>{};
  final _strategiesWriting = <String, int>{};
  final _foldersWriting = <String, int>{};
  final _refusedStrategies = <String, CopyRefusal>{};
  final _refusedFolders = <String, CopyRefusal>{};
  var _working = false;
  var _batches = 0;
  var _noticed = 0;
  var _idle = Completer<void>()..complete();

  MirrorPhase get phase => _phase;

  int get batches => _batches;

  Map<String, CopyRefusal> get refusedStrategies =>
      Map.unmodifiable(_refusedStrategies);

  Map<String, CopyRefusal> get refusedFolders =>
      Map.unmodifiable(_refusedFolders);

  int get pending => _strategies.length + _folders.length;

  @override
  void onWriting(LibraryTouch touch) {
    _noticed++;
    for (final id in touch.strategies) {
      _strategiesWriting[id] = (_strategiesWriting[id] ?? 0) + 1;
    }
    for (final id in touch.folders) {
      _foldersWriting[id] = (_foldersWriting[id] ?? 0) + 1;
    }
  }

  @override
  void onAnswered(LibraryTouch touch) {
    _noticed++;
    _settle(_strategiesWriting, touch.strategies);
    _settle(_foldersWriting, touch.folders);
    _strategies.addAll(touch.strategies);
    _folders.addAll(touch.folders);
    _kick();
  }

  @override
  void onFault(Object error, StackTrace stackTrace) =>
      _stop(MirrorFaulted(error, stackTrace));

  static void _settle(Map<String, int> writing, List<String> ids) {
    for (final id in ids) {
      switch (writing[id]) {
        case null || 1:
          writing.remove(id);
        case final count:
          writing[id] = count - 1;
      }
    }
  }

  void _stop(MirrorStop stop) {
    _phase = MirrorStopped(stop);
    _working = false;
    if (!_idle.isCompleted) _idle.complete();
  }

  Future<ShadowCopy> copyThenFollow(
    LibraryStore store, {
    required LibraryBoxWrites writes,
    void Function(int done, int total)? progress,
  }) async {
    _working = true;
    _idle = Completer<void>();
    final copy = await copyHiveIntoStore(
      readHive,
      store,
      writes: writes,
      breathe: betweenAnimations,
      progress: progress,
    );
    _record(copy, const {}, const {});
    _working = false;
    switch ((copy, store.library)) {
      case (ShadowCopyStopped(:final stop), _):
        _stop(MirrorStoreStopped(stop));
      case (_, LibraryShut(:final failure)):
        _stop(MirrorStoreStopped(StoreDidNotRead(failure)));
      case (
          ShadowCopyFinished() || ShadowCopyRaced(),
          LibraryOpen(:final list)
        ):
        _phase = MirrorFollowing(store, StoreHolds.of(list));
    }
    _kick();
    return copy;
  }

  void hold() {
    if (_phase case MirrorFollowing()) _phase = const MirrorHeld();
  }

  Future<void> drained() => _idle.future;

  Future<StoreCheck> check(Future<StoreCheck> Function() run) async {
    while (_working || _hasWork) {
      if (!_working) _kick();
      if (_idle.isCompleted) break;
      await _idle.future;
    }
    _working = true;
    if (_idle.isCompleted) _idle = Completer<void>();
    final before = _noticed;
    final StoreCheck checked;
    try {
      checked = await run();
    } finally {
      _working = false;
      _kick();
    }
    return _noticed == before
        ? checked
        : StoreChangedDuringCheck(checked, _noticed - before);
  }

  bool get _hasWork =>
      _phase is MirrorFollowing &&
      (_strategies.any((id) => !_strategiesWriting.containsKey(id)) ||
          _folders.any((id) => !_foldersWriting.containsKey(id)));

  ({Set<String> strategies, Set<String> folders}) _choose() => (
        strategies: {
          for (final id in {..._strategies, ..._refusedStrategies.keys})
            if (!_strategiesWriting.containsKey(id)) id,
        },
        folders: {
          for (final id in {..._folders, ..._refusedFolders.keys})
            if (!_foldersWriting.containsKey(id)) id,
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
      final batch = await mirrorIds(
        reads,
        store,
        holds,
        strategies: strategies,
        folders: folders,
      );
      _batches++;
      _record(batch, strategies, folders);
      if (batch case ShadowCopyStopped(:final stop)) {
        _stop(MirrorStoreStopped(stop));
        return;
      }
    }
  }

  void _record(ShadowCopy copy, Set<String> strategies, Set<String> folders) {
    _refusedStrategies.removeWhere((id, _) => strategies.contains(id));
    _refusedFolders.removeWhere((id, _) => folders.contains(id));
    for (final strategy in copy.strategies) {
      switch (strategy) {
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
        case FolderNotCopied(:final folderId, :final reason):
          _refusedFolders[folderId] = reason;
        case FolderCopied(:final folderId) ||
              FolderUnchanged(:final folderId) ||
              FolderRemovedWithHive(:final folderId):
          _refusedFolders.remove(folderId);
      }
    }
  }
}
