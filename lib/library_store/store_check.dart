import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/folder_as_row.dart';
import 'package:icarus/library_rows/strategy_comparison.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/hive_record.dart';
import 'package:icarus/library_store/rows_digest.dart';
import 'package:icarus/library_store/stored_strategy.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

final class FieldDifference {
  const FieldDifference({
    required this.pageId,
    required this.path,
    required this.kind,
  });

  final String? pageId;
  final String path;
  final DifferenceKind kind;

  @override
  String toString() =>
      '${kind.name} ${pageId == null ? '' : 'page $pageId '}$path';
}

sealed class StrategyCheck {
  const StrategyCheck(this.strategyId);

  final String strategyId;
}

final class StrategySame extends StrategyCheck {
  const StrategySame(super.strategyId);
}

enum RowDifferenceKind { missingFromStore, notFromHive, content }

final class RowDifference {
  const RowDifference(this.key, this.kind);

  final String key;
  final RowDifferenceKind kind;

  @override
  String toString() => '${kind.name} $key';
}

final class StrategyDiffers extends StrategyCheck {
  StrategyDiffers(
    super.strategyId, {
    required List<RowDifference> rows,
    required List<FieldDifference> fields,
  })  : rows = List.unmodifiable(rows),
        fields = List.unmodifiable(fields);

  final List<RowDifference> rows;
  final List<FieldDifference> fields;

  @override
  String toString() =>
      'StrategyDiffers($strategyId: ${[...rows, ...fields].join(', ')})';
}

final class StrategyNotConverted extends StrategyCheck {
  const StrategyNotConverted(super.strategyId, this.problems);

  final List<RowsProblem> problems;
}

final class StrategyRowsNotEncodable extends StrategyCheck {
  const StrategyRowsNotEncodable(super.strategyId, this.notDigested);

  final RowsNotDigested notDigested;
}

final class StrategyNotListed extends StrategyCheck {
  const StrategyNotListed(super.strategyId);
}

final class RecordWithoutStrategy extends StrategyCheck {
  const RecordWithoutStrategy(super.strategyId);
}

final class StrategyMissingFromStore extends StrategyCheck {
  const StrategyMissingFromStore(super.strategyId);
}

final class StrategyUnreadableInStore extends StrategyCheck {
  const StrategyUnreadableInStore(super.strategyId, this.stored);

  final StoredUnreadable stored;
}

final class StrategyNotInHive extends StrategyCheck {
  const StrategyNotInHive(super.strategyId);
}

final class StrategyRecordStale extends StrategyCheck {
  const StrategyRecordStale(super.strategyId, this.recorded, this.hiveNow);

  final String? recorded;
  final String hiveNow;
}

sealed class FolderCheck {
  const FolderCheck(this.folderId);

  final String folderId;
}

final class FolderSame extends FolderCheck {
  const FolderSame(super.folderId);
}

final class FolderDiffers extends FolderCheck {
  FolderDiffers(super.folderId, List<String> fields)
      : fields = List.unmodifiable(fields);

  final List<String> fields;
}

final class FolderMissingFromStore extends FolderCheck {
  const FolderMissingFromStore(super.folderId);
}

final class FolderUnreadableInStore extends FolderCheck {
  const FolderUnreadableInStore(super.folderId, this.problem);

  final String problem;
}

final class FolderNotInHive extends FolderCheck {
  const FolderNotInHive(super.folderId);
}

sealed class StoreCheck {
  const StoreCheck();
}

final class StoreChecked extends StoreCheck {
  StoreChecked({
    required this.hiveStrategies,
    required this.hiveFolders,
    required List<StrategyCheck> strategies,
    required List<FolderCheck> folders,
    required List<UnplacedRow> unplaced,
  })  : strategies = List.unmodifiable(strategies),
        folders = List.unmodifiable(folders),
        unplaced = List.unmodifiable(unplaced);

  final int hiveStrategies;
  final int hiveFolders;
  final List<StrategyCheck> strategies;
  final List<FolderCheck> folders;
  final List<UnplacedRow> unplaced;

  int get sameStrategies => strategies.whereType<StrategySame>().length;

  int get sameFolders => folders.whereType<FolderSame>().length;

  List<StrategyCheck> get strategyProblems => [
        for (final check in strategies)
          if (check is! StrategySame) check
      ];

  List<FolderCheck> get folderProblems => [
        for (final check in folders)
          if (check is! FolderSame) check
      ];

  bool get isExact =>
      sameStrategies == hiveStrategies &&
      sameFolders == hiveFolders &&
      strategyProblems.isEmpty &&
      folderProblems.isEmpty &&
      unplaced.isEmpty;
}

final class StoreNotChecked extends StoreCheck {
  const StoreNotChecked(this.failure);

  final StorageFailure failure;
}

Future<StoreCheck> checkStoreAgainstHive(
  HiveLibrary hive,
  LibraryStore store, {
  required Future<void> Function() breathe,
}) async {
  final strategies = <StrategyCheck>[];
  switch (await store.findStrategies()) {
    case StrategiesNotSearched(:final failure):
      return StoreNotChecked(failure);
    case StrategiesFound(:final rebuilt):
      for (final summary in rebuilt) {
        strategies.add(StrategyNotListed(summary.publicId));
      }
  }
  final LibraryList list;
  switch (store.library) {
    case LibraryOpen(list: final open):
      list = open;
    case LibraryShut(:final failure):
      return StoreNotChecked(failure);
  }
  final hiveIds = <String>{};
  for (final expected in hive.strategies) {
    hiveIds.add(expected.id);
    switch (await _checkOne(store, expected, list.hiveRecords[expected.id])) {
      case _Checked(:final checks):
        strategies.addAll(checks);
      case _NotRead(:final failure):
        return StoreNotChecked(failure);
    }
    await breathe();
  }
  final listed = {for (final summary in list.strategies) summary.publicId};
  for (final id in listed.difference(hiveIds)) {
    strategies.add(StrategyNotInHive(id));
  }
  for (final id in list.hiveRecords.keys.toSet().difference(listed)) {
    strategies.add(RecordWithoutStrategy(id));
  }
  for (final listing in list.unreadableStrategies) {
    strategies.add(
      StrategyUnreadableInStore(
        switch (listing.header) {
          HeaderPlaced(:final row) => row.publicId,
          HeaderUnplaced() || HeaderAbsent() => listing.ref.area,
        },
        StoredUnreadable(['listed as unreadable: ${listing.ref}']),
      ),
    );
  }
  return StoreChecked(
    hiveStrategies: hive.strategies.length,
    hiveFolders: hive.folders.length,
    strategies: strategies,
    folders: _checkFolders(hive.folders, list.folders),
    unplaced: list.unplaced,
  );
}

sealed class _OneCheck {
  const _OneCheck();
}

final class _Checked extends _OneCheck {
  const _Checked(this.checks);

  final List<StrategyCheck> checks;
}

final class _NotRead extends _OneCheck {
  const _NotRead(this.failure);

  final StorageFailure failure;
}

Future<_OneCheck> _checkOne(
  LibraryStore store,
  StrategyData expected,
  HiveRecordDigest? recorded,
) async {
  final id = expected.id;
  final RowsDigested hive;
  switch (strategyToRows(expected)) {
    case StrategyRowsRefused(:final problems):
      return _Checked([StrategyNotConverted(id, problems)]);
    case StrategyRowsMade(:final rows):
      switch (rowsDigestOf(rows)) {
        case final RowsNotDigested notDigested:
          return _Checked([StrategyRowsNotEncodable(id, notDigested)]);
        case final RowsDigested digested:
          hive = digested;
      }
  }
  final stale = [
    if (recorded?.digest != hive.digest)
      StrategyRecordStale(id, recorded?.digest, hive.digest),
  ];
  return switch (await _compared(store, expected, hive.rows)) {
    _Checked(:final checks) => _Checked([...stale, ...checks]),
    final _NotRead notRead => notRead,
  };
}

Future<_OneCheck> _compared(
  LibraryStore store,
  StrategyData expected,
  Map<String, String> hiveRows,
) async {
  final id = expected.id;
  final StrategyRowSet storedRows;
  switch (await readStoredRows(store, id)) {
    case StoredRowsNot(stored: StoredNotRead(:final failure)):
      return _NotRead(failure);
    case StoredRowsNot(stored: StoredMissing()):
      return _Checked([StrategyMissingFromStore(id)]);
    case StoredRowsNot(stored: final StoredUnreadable unreadable):
      return _Checked([StrategyUnreadableInStore(id, unreadable)]);
    case StoredRowsNot(stored: StoredAsData()):
      return _Checked([StrategyMissingFromStore(id)]);
    case StoredRowsRead(:final rows):
      storedRows = rows;
  }
  final Map<String, String> inStore;
  switch (rowsDigestOf(storedRows)) {
    case final RowsNotDigested notDigested:
      return _Checked([StrategyRowsNotEncodable(id, notDigested)]);
    case RowsDigested(rows: final texts):
      inStore = texts;
  }
  final rows = [
    for (final key in hiveRows.keys)
      if (!inStore.containsKey(key))
        RowDifference(key, RowDifferenceKind.missingFromStore)
      else if (inStore[key] != hiveRows[key])
        RowDifference(key, RowDifferenceKind.content),
    for (final key in inStore.keys)
      if (!hiveRows.containsKey(key))
        RowDifference(key, RowDifferenceKind.notFromHive),
  ];
  final fields = switch (strategyOfRows(storedRows)) {
    StoredAsData(strategy: final actual) => _differences(expected, actual),
    StoredUnreadable(:final problems) => [
        for (final problem in problems)
          FieldDifference(
            pageId: null,
            path: problem,
            kind: DifferenceKind.value,
          ),
      ],
    StoredMissing() || StoredNotRead() => const <FieldDifference>[],
  };
  return _Checked([
    if (rows.isEmpty && fields.isEmpty)
      StrategySame(id)
    else
      StrategyDiffers(id, rows: rows, fields: fields),
  ]);
}

List<FieldDifference> _differences(StrategyData expected, StrategyData actual) {
  final pages = [...expected.pages]..sort(
      (a, b) => a.sortIndex != b.sortIndex
          ? a.sortIndex.compareTo(b.sortIndex)
          : a.id.compareTo(b.id),
    );
  final pageAt = RegExp(r'^pages\[(\d+)\]');
  return [
    for (final difference in strategyDifferences(expected, actual))
      FieldDifference(
        pageId: switch (pageAt.firstMatch(difference.path)?.group(1)) {
          final index? when int.parse(index) < pages.length =>
            pages[int.parse(index)].id,
          _ => null,
        },
        path: difference.path,
        kind: difference.kind,
      ),
  ];
}

List<FolderCheck> _checkFolders(List<Folder> hive, List<FolderRow> stored) {
  final byId = {for (final row in stored) row.publicId: row};
  final hiveIds = {for (final folder in hive) folder.id};
  return [
    for (final folder in hive)
      switch (byId[folder.id]) {
        null => FolderMissingFromStore(folder.id),
        UnreadableFolder(:final problem) =>
          FolderUnreadableInStore(folder.id, problem),
        final ReadableFolder row => switch (folderFromRow(row)) {
            FolderRefused(:final problems) => FolderUnreadableInStore(
                folder.id,
                problems.map((problem) => problem.runtimeType).join(', '),
              ),
            FolderMade(folder: final back) => switch (_folderFields(
                folder,
                back,
              )) {
                [] => FolderSame(folder.id),
                final fields => FolderDiffers(folder.id, fields),
              },
          },
      },
    for (final row in stored)
      if (!hiveIds.contains(row.publicId)) FolderNotInHive(row.publicId),
  ];
}

List<String> _folderFields(Folder expected, Folder actual) => [
      if (actual.name != expected.name) 'name',
      if (actual.parentID != expected.parentID) 'parentID',
      if (actual.dateCreated != expected.dateCreated) 'dateCreated',
      if (actual.iconId != expected.iconId) 'iconId',
      if (actual.color != expected.color) 'color',
      if (actual.customColor?.toARGB32() != expected.customColor?.toARGB32())
        'customColor',
    ];
