import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/folder_as_row.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/hive_record.dart';
import 'package:icarus/library_store/rows_digest.dart';
import 'package:icarus/library_store/storage_failure_words.dart';
import 'package:icarus/library_store/stored_strategy.dart';
import 'package:icarus/strategy/strategy_models.dart';
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

final class StrategyChangedOnBothSides extends StrategyCopy {
  const StrategyChangedOnBothSides(
    super.strategyId, {
    required this.copiedFrom,
    required this.hiveNow,
    required this.storeNow,
  });

  final String copiedFrom;
  final String hiveNow;
  final String storeNow;
}

final class StrategyRemovedWithHive extends StrategyCopy {
  const StrategyRemovedWithHive(super.strategyId);
}

final class StrategyNotCopied extends StrategyCopy {
  const StrategyNotCopied(super.strategyId, this.reason);

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
  String toString() => 'the store refused it: $refusal';
}

final class StoreCopyUnreadable extends CopyRefusal {
  const StoreCopyUnreadable(this.stored);

  final StoredStrategy stored;

  @override
  String toString() => 'the store\'s copy could not be read back: $stored';
}

final class RowsNotEncodable extends CopyRefusal {
  const RowsNotEncodable(this.notDigested);

  final RowsNotDigested notDigested;

  @override
  String toString() => 'a row it converts to is not JSON: $notDigested';
}

final class StoreCouldNotEncode extends CopyRefusal {
  const StoreCouldNotEncode(this.failure);

  final WouldNotReadBack failure;

  @override
  String toString() =>
      '${storageFailureWords(failure, StoreStep.refusedSave)} ($failure)';
}

final class StoreHoldsItWithoutRecord extends CopyRefusal {
  const StoreHoldsItWithoutRecord();

  @override
  String toString() => 'the store holds it without a Hive record';
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

sealed class _Edit {
  const _Edit();
}

final class _Edited extends _Edit {
  const _Edited();
}

final class _EditRefused extends _Edit {
  const _EditRefused(this.refusal);

  final LibraryRefusal refusal;
}

final class _EditNotEncoded extends _Edit {
  const _EditNotEncoded(this.failure);

  final WouldNotReadBack failure;
}

final class _EditStopped extends _Edit {
  const _EditStopped(this.stop);

  final CopyStop stop;
}

Future<_Edit> _edit(LibraryStore store, List<LibraryChange> changes) async =>
    switch (await store.editLibrary(changes)) {
      Saved() || NothingToSave() => const _Edited(),
      Refused(:final reason) => _EditRefused(reason),
      NotSaved(failure: final WouldNotReadBack failure) =>
        _EditNotEncoded(failure),
      NotSaved(:final failure) => _EditStopped(StoreDidNotSave(failure)),
      SaveInDoubt(:final failure) => _EditStopped(StoreSaveInDoubt(failure)),
    };

sealed class _Step {
  const _Step();
}

final class _Done extends _Step {
  const _Done(this.copy);

  final StrategyCopy copy;
}

final class _Stopped extends _Step {
  const _Stopped(this.stop);

  final CopyStop stop;
}

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
    if (storedFolders[folder.id] == row) {
      folders.add(FolderUnchanged(folder.id));
      continue;
    }
    switch (await _edit(store, [PutFolder(row)])) {
      case _Edited():
        folders.add(FolderCopied(folder.id));
      case _EditRefused(:final refusal):
        folders.add(FolderNotCopied(folder.id, StoreRefusedIt(refusal)));
      case _EditNotEncoded(:final failure):
        folders.add(FolderNotCopied(folder.id, StoreCouldNotEncode(failure)));
      case _EditStopped(:final stop):
        return stopped(stop);
    }
  }

  final stored = {for (final summary in list.strategies) summary.publicId};
  final unreadableIds = {
    for (final listing in list.unreadableStrategies)
      if (listing.header case HeaderPlaced(:final row)) row.publicId,
  };
  final hiveIds = {for (final strategy in hive.strategies) strategy.id};
  final total = hive.strategies.length;
  for (final (index, strategy) in hive.strategies.indexed) {
    final step = await _copyOne(
      store,
      strategy,
      recorded: list.hiveRecords[strategy.id],
      inStore:
          stored.contains(strategy.id) || unreadableIds.contains(strategy.id),
    );
    switch (step) {
      case _Done(:final copy):
        strategies.add(copy);
      case _Stopped(:final stop):
        return stopped(stop);
    }
    progress?.call(index + 1, total);
    await breathe();
  }

  for (final id in list.hiveRecords.keys) {
    if (hiveIds.contains(id)) continue;
    switch (await _edit(store, [RemoveStrategy(id)])) {
      case _Edited():
        strategies.add(StrategyRemovedWithHive(id));
      case _EditRefused(:final refusal):
        strategies.add(StrategyNotCopied(id, StoreRefusedIt(refusal)));
      case _EditNotEncoded(:final failure):
        strategies.add(StrategyNotCopied(id, StoreCouldNotEncode(failure)));
      case _EditStopped(:final stop):
        return stopped(stop);
    }
  }

  final hiveFolderIds = {for (final folder in hive.folders) folder.id};
  final leaving = [
    for (final row in list.folders)
      if (!hiveFolderIds.contains(row.publicId)) row,
  ];
  for (final row in _childrenFirst(leaving)) {
    switch (await _edit(store, [RemoveFolder(row.publicId)])) {
      case _Edited():
        folders.add(FolderRemovedWithHive(row.publicId));
      case _EditRefused(:final refusal):
        folders.add(FolderNotCopied(row.publicId, StoreRefusedIt(refusal)));
      case _EditNotEncoded(:final failure):
        folders.add(
          FolderNotCopied(row.publicId, StoreCouldNotEncode(failure)),
        );
      case _EditStopped(:final stop):
        return stopped(stop);
    }
  }
  return ShadowCopyFinished(strategies, folders);
}

Future<_Step> _copyOne(
  LibraryStore store,
  StrategyData strategy, {
  required HiveRecordDigest? recorded,
  required bool inStore,
}) async {
  final id = strategy.id;
  final StrategyRowSet hiveRows;
  switch (strategyToRows(strategy)) {
    case StrategyRowsRefused(:final problems):
      return _Done(StrategyNotCopied(id, ConverterRefused(problems)));
    case StrategyRowsMade(:final rows):
      hiveRows = rows;
  }
  final String digest;
  switch (rowsDigestOf(hiveRows)) {
    case final RowsNotDigested notDigested:
      return _Done(StrategyNotCopied(id, RowsNotEncodable(notDigested)));
    case RowsDigested(digest: final digested):
      digest = digested;
  }
  switch (recorded) {
    case null when inStore:
      return _Done(StrategyNotCopied(id, const StoreHoldsItWithoutRecord()));
    case null:
      return _addRows(
        store,
        hiveRows,
        HiveRecordDigest(strategyPublicId: id, digest: digest),
        StrategyCopied(id),
      );
    case HiveRecordDigest(digest: final copied) when copied == digest:
      return _Done(StrategyUnchanged(id));
    case HiveRecordDigest(digest: final copied):
      final StrategyRowSet storedRows;
      switch (await readStoredRows(store, id)) {
        case StoredRowsNot(stored: StoredNotRead(:final failure)):
          return _Stopped(StoreDidNotRead(failure));
        case StoredRowsNot(:final stored):
          return _Done(StrategyNotCopied(id, StoreCopyUnreadable(stored)));
        case StoredRowsRead(:final rows):
          storedRows = rows;
      }
      final String storeNow;
      switch (rowsDigestOf(storedRows)) {
        case final RowsNotDigested notDigested:
          return _Done(StrategyNotCopied(id, RowsNotEncodable(notDigested)));
        case RowsDigested(digest: final digested):
          storeNow = digested;
      }
      if (storeNow != copied) {
        return _Done(
          StrategyChangedOnBothSides(
            id,
            copiedFrom: copied,
            hiveNow: digest,
            storeNow: storeNow,
          ),
        );
      }
      return _takeHiveVersion(
        store,
        stored: storedRows,
        hive: hiveRows,
        record: recorded.withDigest(digest),
      );
  }
}

Future<_Step> _addRows(
  LibraryStore store,
  StrategyRowSet rows,
  HiveRecordDigest record,
  StrategyCopy copied,
) async =>
    switch (await _edit(store, [
      AddStrategy(rows),
      RememberHiveRecord(record),
    ])) {
      _Edited() => _Done(copied),
      _EditRefused(:final refusal) => _Done(
          StrategyNotCopied(record.strategyPublicId, StoreRefusedIt(refusal)),
        ),
      _EditNotEncoded(:final failure) => _Done(
          StrategyNotCopied(
            record.strategyPublicId,
            StoreCouldNotEncode(failure),
          ),
        ),
      _EditStopped(:final stop) => _Stopped(stop),
    };

Future<_Step> _takeHiveVersion(
  LibraryStore store, {
  required StrategyRowSet stored,
  required StrategyRowSet hive,
  required HiveRecordDigest record,
}) async {
  final id = record.strategyPublicId;
  switch (await _edit(store, [RemoveStrategy(id)])) {
    case _Edited():
      return _addRows(store, hive, record, StrategyTookHiveVersion(id));
    case _EditRefused(:final refusal):
      return _Done(StrategyNotCopied(id, StoreRefusedIt(refusal)));
    case _EditNotEncoded(:final failure):
      return _Done(StrategyNotCopied(id, StoreCouldNotEncode(failure)));
    case _EditStopped(:final stop):
      return _Stopped(stop);
  }
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
