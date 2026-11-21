import 'dart:async';

import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/library_box_writes.dart';
import 'package:icarus/library_store/shadow_copy.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus_library/icarus_library.dart';

sealed class MirrorPhase {
  const MirrorPhase();
}

final class MirrorWaitingForStore extends MirrorPhase {
  const MirrorWaitingForStore();
}

final class MirrorFollowing extends MirrorPhase {
  const MirrorFollowing(this.store);

  final LibraryStore store;
}

final class MirrorHeld extends MirrorPhase {
  const MirrorHeld(this.store);

  final LibraryStore store;
}

final class MirrorStopped extends MirrorPhase {
  const MirrorStopped(this.stop);

  final CopyStop stop;
}

final class StoreMirror implements LocalLibraryFollower {
  StoreMirror({required this.readHive, required this.breathe});

  final HiveLibrary Function() readHive;
  final Future<void> Function() breathe;

  MirrorPhase _phase = const MirrorWaitingForStore();
  final _strategies = <String>{};
  final _folders = <String>{};
  final _refusedStrategies = <String, CopyRefusal>{};
  final _refusedFolders = <String, CopyRefusal>{};
  var _working = false;
  var _batches = 0;
  var _idle = Completer<void>()..complete();

  MirrorPhase get phase => _phase;

  int get batches => _batches;

  Map<String, CopyRefusal> get refusedStrategies =>
      Map.unmodifiable(_refusedStrategies);

  Map<String, CopyRefusal> get refusedFolders =>
      Map.unmodifiable(_refusedFolders);

  int get pending => _strategies.length + _folders.length;

  @override
  void saved({
    required Iterable<String> strategies,
    required Iterable<String> folders,
  }) {
    _strategies.addAll(strategies);
    _folders.addAll(folders);
    _kick();
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
      breathe: breathe,
      progress: progress,
    );
    _record(copy);
    _working = false;
    _phase = switch (copy) {
      ShadowCopyStopped(:final stop) => MirrorStopped(stop),
      ShadowCopyFinished() || ShadowCopyRaced() => MirrorFollowing(store),
    };
    _kick();
    return copy;
  }

  void hold() {
    if (_phase case MirrorFollowing(:final store)) _phase = MirrorHeld(store);
  }

  Future<void> drained() => _idle.future;

  void _kick() {
    if (_working) return;
    switch (_phase) {
      case MirrorFollowing() when pending > 0:
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
    while (true) {
      final LibraryStore store;
      switch (_phase) {
        case MirrorFollowing(store: final following) when pending > 0:
          store = following;
        case MirrorFollowing() ||
              MirrorHeld() ||
              MirrorStopped() ||
              MirrorWaitingForStore():
          _working = false;
          _kick();
          return;
      }
      final strategies = {..._strategies};
      final folders = {..._folders};
      _strategies.clear();
      _folders.clear();
      final batch = await mirrorChanges(
        readHive,
        store,
        strategies: strategies,
        folders: folders,
        breathe: breathe,
      );
      _batches++;
      _record(batch);
      if (batch case ShadowCopyStopped(:final stop)) {
        _phase = MirrorStopped(stop);
      }
    }
  }

  void _record(ShadowCopy copy) {
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
