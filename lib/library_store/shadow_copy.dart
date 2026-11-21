import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/folder_as_row.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/hive_library.dart';
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

final class ShadowCopyStopped extends ShadowCopy {
  ShadowCopyStopped(super.strategies, super.folders, this.stop);

  final CopyStop stop;
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
  HiveLibrary hive,
  LibraryStore store, {
  required Future<void> Function() breathe,
  void Function(int done, int total)? progress,
}) async {
  final strategies = <StrategyCopy>[];
  final folders = <FolderCopy>[];
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
  final hiveIds = {for (final strategy in hive.strategies) strategy.id};
  final total = hive.strategies.length;
  for (final (index, strategy) in hive.strategies.indexed) {
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
    progress?.call(index + 1, total);
    await breathe();
  }

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

  final hiveFolderIds = {for (final folder in hive.folders) folder.id};
  final leaving = [
    for (final row in list.folders)
      if (!hiveFolderIds.contains(row.publicId)) row,
  ];
  for (final row in _childrenFirst(leaving)) {
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
