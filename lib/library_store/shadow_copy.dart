import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/folder_as_row.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/hive_reads.dart';
import 'package:icarus/library_store/library_box_writes.dart';
import 'package:icarus/library_store/storage_failure_words.dart';
import 'package:icarus_library/icarus_library.dart';

sealed class StrategyCopy {
  const StrategyCopy(this.strategyId);

  final String strategyId;
}

final class StrategyCopied extends StrategyCopy {
  const StrategyCopied(super.strategyId);
}

final class StrategyUnchanged extends StrategyCopy {
  const StrategyUnchanged(super.strategyId);
}

final class StrategyTookHiveVersion extends StrategyCopy {
  const StrategyTookHiveVersion(super.strategyId);
}

final class StrategyRemovedWithHive extends StrategyCopy {
  const StrategyRemovedWithHive(super.strategyId);
}

final class StrategyWaitsForHive extends StrategyCopy {
  const StrategyWaitsForHive(super.strategyId);
}

final class StrategyNotMirrored extends StrategyCopy {
  const StrategyNotMirrored(super.strategyId, this.reason);

  final CopyRefusal reason;
}

sealed class CopyRefusal {
  const CopyRefusal();
}

final class ConverterRefused extends CopyRefusal {
  const ConverterRefused(this.problems);

  final List<RowsProblem> problems;

  @override
  String toString() =>
      'the converter refused it: ${problems.map((p) => p.runtimeType).join(', ')}';
}

final class StoreRefusedIt extends CopyRefusal {
  const StoreRefusedIt(this.refusal);

  final LibraryRefusal refusal;

  @override
  String toString() => switch (refusal) {
        PutWouldDrop(:final ref, :final dropped) =>
          'the store holds what a copy would drop: ${dropped.name} at $ref',
        final other => 'the store refused it: $other',
      };
}

final class StoreCouldNotEncode extends CopyRefusal {
  const StoreCouldNotEncode(this.failure);

  final WouldNotReadBack failure;

  @override
  String toString() =>
      '${storageFailureWords(failure, StoreStep.refusedSave)} ($failure)';
}

sealed class FolderCopy {
  const FolderCopy(this.folderId);

  final String folderId;
}

final class FolderCopied extends FolderCopy {
  const FolderCopied(super.folderId);
}

final class FolderUnchanged extends FolderCopy {
  const FolderUnchanged(super.folderId);
}

final class FolderRemovedWithHive extends FolderCopy {
  const FolderRemovedWithHive(super.folderId);
}

final class FolderWaitsForHive extends FolderCopy {
  const FolderWaitsForHive(super.folderId);
}

final class FolderNotCopied extends FolderCopy {
  const FolderNotCopied(super.folderId, this.reason);

  final CopyRefusal reason;
}

sealed class CopyStop {
  const CopyStop(this.failure);

  final StorageFailure failure;

  StoreStep get step;

  @override
  String toString() => '${storageFailureWords(failure, step)} ($failure)';
}

final class StoreDidNotSave extends CopyStop {
  const StoreDidNotSave(super.failure);

  @override
  StoreStep get step => StoreStep.refusedSave;
}

final class StoreSaveInDoubt extends CopyStop {
  const StoreSaveInDoubt(super.failure);

  @override
  StoreStep get step => StoreStep.saveInDoubt;
}

final class StoreDidNotRead extends CopyStop {
  const StoreDidNotRead(super.failure);

  @override
  StoreStep get step => StoreStep.read;
}

sealed class ShadowCopy {
  ShadowCopy(List<StrategyCopy> strategies, List<FolderCopy> folders)
      : strategies = List.unmodifiable(strategies),
        folders = List.unmodifiable(folders);

  final List<StrategyCopy> strategies;
  final List<FolderCopy> folders;
}

final class ShadowCopyFinished extends ShadowCopy {
  ShadowCopyFinished(super.strategies, super.folders);
}

final class ShadowCopyRaced extends ShadowCopy {
  ShadowCopyRaced(super.strategies, super.folders, this.hiveWrites);

  final int hiveWrites;
}

final class ShadowCopyStopped extends ShadowCopy {
  ShadowCopyStopped(super.strategies, super.folders, this.stop);

  final CopyStop stop;
}

final class ShadowCopyFaulted extends ShadowCopy {
  ShadowCopyFaulted(this.error, this.stackTrace) : super(const [], const []);

  final Object error;
  final StackTrace stackTrace;
}

sealed class _Saving {
  const _Saving();
}

final class _Wrote extends _Saving {
  const _Wrote();
}

final class _NothingToWrite extends _Saving {
  const _NothingToWrite();
}

final class _NotWritten extends _Saving {
  const _NotWritten(this.reason);

  final CopyRefusal reason;
}

final class _Stop extends _Saving {
  const _Stop(this.stop);

  final CopyStop stop;
}

_Saving _saving(LibraryEditResult result) => switch (result) {
      Saved() => const _Wrote(),
      NothingToSave() => const _NothingToWrite(),
      Refused(:final reason) => _NotWritten(StoreRefusedIt(reason)),
      NotSaved(failure: final WouldNotReadBack failure) =>
        _NotWritten(StoreCouldNotEncode(failure)),
      NotSaved(:final failure) => _Stop(StoreDidNotSave(failure)),
      SaveInDoubt(:final failure) => _Stop(StoreSaveInDoubt(failure)),
    };

Future<ShadowCopy> copyHiveIntoStore(
  HiveReads reads,
  LibraryStore store, {
  required LibraryBoxWrites writes,
  required Future<void> Function() breathe,
  void Function(int done, int total)? progress,
}) async {
  final copy = await _bringUpToDate(
    reads,
    store,
    breathe: breathe,
    progress: progress,
  );
  return switch (copy) {
    ShadowCopyFinished(:final strategies, :final folders)
        when writes.count > 0 =>
      ShadowCopyRaced(strategies, folders, writes.count),
    _ => copy,
  };
}

final class StoreHolds {
  StoreHolds({required this.strategies, required this.folders});

  StoreHolds.of(LibraryList list)
      : strategies = {for (final summary in list.strategies) summary.publicId},
        folders = {for (final row in list.folders) row.publicId: row};

  final Set<String> strategies;
  final Map<String, FolderRow> folders;
}

Future<ShadowCopy> mirrorIds(
  HiveReads reads,
  LibraryStore store,
  StoreHolds holds, {
  required Set<String> strategies,
  required Set<String> folders,
}) async {
  final strategyResults = <StrategyCopy>[];
  final folderResults = <FolderCopy>[];
  ShadowCopy stopped(CopyStop stop) =>
      ShadowCopyStopped(strategyResults, folderResults, stop);

  final present = <String, Folder>{};
  final absent = <String>{};
  for (final id in folders) {
    switch (reads.folder(id)) {
      case InHive(value: final folder):
        present[id] = folder;
      case NotInHive():
        absent.add(id);
      case HiveStillWriting():
        folderResults.add(FolderWaitsForHive(id));
    }
  }
  for (final folder in _parentsFirst(present.values.toList())) {
    final row = _folderRow(folder, holds.folders[folder.id]);
    switch (_saving(await store.editLibrary([PutFolder(row)]))) {
      case _Wrote():
        holds.folders[folder.id] = row;
        folderResults.add(FolderCopied(folder.id));
      case _NothingToWrite():
        holds.folders[folder.id] = row;
        folderResults.add(FolderUnchanged(folder.id));
      case _NotWritten(:final reason):
        folderResults.add(FolderNotCopied(folder.id, reason));
      case _Stop(:final stop):
        return stopped(stop);
    }
  }

  for (final id in strategies) {
    switch (reads.strategy(id)) {
      case InHive(value: final strategy):
        switch (strategyToRows(strategy)) {
          case StrategyRowsRefused(:final problems):
            strategyResults
                .add(StrategyNotMirrored(id, ConverterRefused(problems)));
          case StrategyRowsMade(:final rows):
            switch (_saving(await store.putStrategy(rows))) {
              case _Wrote():
                strategyResults.add(
                  holds.strategies.contains(id)
                      ? StrategyTookHiveVersion(id)
                      : StrategyCopied(id),
                );
                holds.strategies.add(id);
              case _NothingToWrite():
                holds.strategies.add(id);
                strategyResults.add(StrategyUnchanged(id));
              case _NotWritten(:final reason):
                strategyResults.add(StrategyNotMirrored(id, reason));
              case _Stop(:final stop):
                return stopped(stop);
            }
        }
      case NotInHive() when holds.strategies.contains(id):
        final removal = switch (await store.editLibrary([RemoveStrategy(id)])) {
          Refused(reason: NoSuchStrategy()) => const _NothingToWrite(),
          final result => _saving(result),
        };
        switch (removal) {
          case _Wrote() || _NothingToWrite():
            holds.strategies.remove(id);
            strategyResults.add(StrategyRemovedWithHive(id));
          case _NotWritten(:final reason):
            strategyResults.add(StrategyNotMirrored(id, reason));
          case _Stop(:final stop):
            return stopped(stop);
        }
      case NotInHive():
        break;
      case HiveStillWriting():
        strategyResults.add(StrategyWaitsForHive(id));
    }
  }

  final leaving = [
    for (final id in absent)
      if (holds.folders[id] case final row?) row,
  ];
  for (final row in _childrenFirst(leaving)) {
    switch (reads.folder(row.publicId)) {
      case NotInHive():
        break;
      case HiveStillWriting():
        folderResults.add(FolderWaitsForHive(row.publicId));
        continue;
      case InHive():
        continue;
    }
    switch (_saving(await store.editLibrary([RemoveFolder(row.publicId)]))) {
      case _Wrote() || _NothingToWrite():
        holds.folders.remove(row.publicId);
        folderResults.add(FolderRemovedWithHive(row.publicId));
      case _NotWritten(:final reason):
        folderResults.add(FolderNotCopied(row.publicId, reason));
      case _Stop(:final stop):
        return stopped(stop);
    }
  }
  return ShadowCopyFinished(strategyResults, folderResults);
}

Future<ShadowCopy> _bringUpToDate(
  HiveReads reads,
  LibraryStore store, {
  required Future<void> Function() breathe,
  void Function(int done, int total)? progress,
}) async {
  final snapshot = reads.library();
  final hive = snapshot.library;
  final strategies = <StrategyCopy>[
    for (final id in snapshot.strategiesWriting) StrategyWaitsForHive(id),
  ];
  final folders = <FolderCopy>[
    for (final id in snapshot.foldersWriting) FolderWaitsForHive(id),
  ];
  ShadowCopy stopped(CopyStop stop) =>
      ShadowCopyStopped(strategies, folders, stop);

  final LibraryList list;
  switch (store.library) {
    case LibraryOpen(list: final open):
      list = open;
    case LibraryShut(:final failure):
      return stopped(StoreDidNotRead(failure));
  }
  final storedFolders = {for (final row in list.folders) row.publicId: row};
  for (final folder in _parentsFirst(hive.folders)) {
    final row = _folderRow(folder, storedFolders[folder.id]);
    switch (_saving(await store.editLibrary([PutFolder(row)]))) {
      case _Wrote():
        folders.add(FolderCopied(folder.id));
      case _NothingToWrite():
        folders.add(FolderUnchanged(folder.id));
      case _NotWritten(:final reason):
        folders.add(FolderNotCopied(folder.id, reason));
      case _Stop(:final stop):
        return stopped(stop);
    }
  }

  final stored = {for (final summary in list.strategies) summary.publicId};
  final chosen = hive.strategies;
  for (final (index, strategy) in chosen.indexed) {
    final id = strategy.id;
    switch (strategyToRows(strategy)) {
      case StrategyRowsRefused(:final problems):
        strategies.add(StrategyNotMirrored(id, ConverterRefused(problems)));
      case StrategyRowsMade(:final rows):
        switch (_saving(await store.putStrategy(rows))) {
          case _Wrote():
            strategies.add(
              stored.contains(id)
                  ? StrategyTookHiveVersion(id)
                  : StrategyCopied(id),
            );
          case _NothingToWrite():
            strategies.add(StrategyUnchanged(id));
          case _NotWritten(:final reason):
            strategies.add(StrategyNotMirrored(id, reason));
          case _Stop(:final stop):
            return stopped(stop);
        }
    }
    progress?.call(index + 1, chosen.length);
    await breathe();
  }

  final now = reads.library();
  final hiveIds = {
    for (final strategy in now.library.strategies) strategy.id,
    ...now.strategiesWriting,
  };
  for (final id in stored.difference(hiveIds)) {
    switch (_saving(await store.editLibrary([RemoveStrategy(id)]))) {
      case _Wrote() || _NothingToWrite():
        strategies.add(StrategyRemovedWithHive(id));
      case _NotWritten(:final reason):
        strategies.add(StrategyNotMirrored(id, reason));
      case _Stop(:final stop):
        return stopped(stop);
    }
  }

  final hiveFolderIds = {
    for (final folder in now.library.folders) folder.id,
    ...now.foldersWriting,
  };
  final leaving = storedFolders.keys.toSet().difference(hiveFolderIds);
  for (final row in _childrenFirst([
    for (final row in list.folders)
      if (leaving.contains(row.publicId)) row,
  ])) {
    switch (_saving(await store.editLibrary([RemoveFolder(row.publicId)]))) {
      case _Wrote() || _NothingToWrite():
        folders.add(FolderRemovedWithHive(row.publicId));
      case _NotWritten(:final reason):
        folders.add(FolderNotCopied(row.publicId, reason));
      case _Stop(:final stop):
        return stopped(stop);
    }
  }
  return ShadowCopyFinished(strategies, folders);
}

ReadableFolder _folderRow(Folder folder, FolderRow? stored) {
  final fromHive = folderToRow(folder);
  return switch (stored) {
    ReadableFolder(:final unknownFields) => ReadableFolder(
        publicId: fromHive.publicId,
        name: fromHive.name,
        parentFolderPublicId: fromHive.parentFolderPublicId,
        iconId: fromHive.iconId,
        color: fromHive.color,
        customColorValue: fromHive.customColorValue,
        createdAt: fromHive.createdAt,
        unknownFields: unknownFields,
      ),
    UnreadableFolder() || null => fromHive,
  };
}

List<Folder> _parentsFirst(List<Folder> folders) {
  final byId = {for (final folder in folders) folder.id: folder};
  final ordered = <Folder>[];
  final placed = <String>{};
  void place(Folder folder, Set<String> walking) {
    if (placed.contains(folder.id) || !walking.add(folder.id)) return;
    if (byId[folder.parentID] case final parent?) place(parent, walking);
    placed.add(folder.id);
    ordered.add(folder);
  }

  for (final folder in folders) {
    place(folder, <String>{});
  }
  return ordered;
}

List<FolderRow> _childrenFirst(List<FolderRow> folders) {
  final parents = {
    for (final row in folders)
      row.publicId: switch (row) {
        ReadableFolder(:final parentFolderPublicId) => parentFolderPublicId,
        UnreadableFolder() => null,
      },
  };
  int depth(String id) {
    final seen = <String>{};
    String? at = parents[id];
    while (at != null && seen.add(at)) {
      at = parents[at];
    }
    return seen.length;
  }

  return [...folders]
    ..sort((a, b) => depth(b.publicId).compareTo(depth(a.publicId)));
}
