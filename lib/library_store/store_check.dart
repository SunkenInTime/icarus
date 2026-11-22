import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/folder_as_row.dart';
import 'package:icarus/library_rows/strategy_comparison.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/row_texts.dart';
import 'package:icarus/library_store/shadow_copy.dart';
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
  const StrategyRowsNotEncodable(super.strategyId, this.notText);

  final RowsNotText notText;
}

final class StrategyWriteRefused extends StrategyCheck {
  const StrategyWriteRefused(super.strategyId, this.reason);

  final CopyRefusal reason;
}

final class StrategyNotListed extends StrategyCheck {
  const StrategyNotListed(super.strategyId);
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

final class FolderWriteRefused extends FolderCheck {
  const FolderWriteRefused(super.folderId, this.reason);

  final CopyRefusal reason;
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
    required List<StrategyCheck> notMirrored,
    required List<ForeignName> foreignNames,
    required List<StrategyCheck> strategies,
    required List<FolderCheck> folders,
    required List<UnplacedRow> unplaced,
  })  : notMirrored = List.unmodifiable(notMirrored),
        foreignNames = List.unmodifiable(foreignNames),
        strategies = List.unmodifiable(strategies),
        folders = List.unmodifiable(folders),
        unplaced = List.unmodifiable(unplaced);

  final int hiveStrategies;
  final int hiveFolders;
  final List<StrategyCheck> notMirrored;
  final List<ForeignName> foreignNames;
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
      notMirrored.isEmpty &&
      foreignNames.isEmpty &&
      sameStrategies == hiveStrategies &&
      sameFolders == hiveFolders &&
      strategyProblems.isEmpty &&
      folderProblems.isEmpty &&
      unplaced.isEmpty;
}

final class StoreChangedDuringCheck extends StoreCheck {
  const StoreChangedDuringCheck(this.checked, this.notices);

  final StoreCheck checked;
  final int notices;
}

final class StoreNotChecked extends StoreCheck {
  const StoreNotChecked(this.failure);

  final StorageFailure failure;
}

Future<StoreCheck> checkStoreAgainstHive(
  HiveLibrary hive,
  LibraryStore store, {
  required List<ForeignName> foreignNames,
  required Future<void> Function() breathe,
  Map<String, CopyRefusal> strategiesRefused = const {},
  Map<String, CopyRefusal> foldersRefused = const {},
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
  final notMirrored = <StrategyCheck>[];
  for (final expected in hive.strategies) {
    hiveIds.add(expected.id);
    switch (await _checkOne(store, expected)) {
      case _Checked(:final checks):
        strategies.addAll(checks);
        notMirrored.addAll(checks.where((check) => check is! StrategySame));
        if (strategiesRefused[expected.id] case final reason?) {
          final refused = StrategyWriteRefused(expected.id, reason);
          strategies.add(refused);
          notMirrored.add(refused);
        }
      case _NotRead(:final failure):
        return StoreNotChecked(failure);
    }
    await breathe();
  }
  final listed = localStrategyIds(list);
  for (final id in listed.difference(hiveIds)) {
    strategies.add(StrategyNotInHive(id));
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
    notMirrored: notMirrored,
    foreignNames: foreignNames,
    strategies: strategies,
    folders: [
      ..._checkFolders(hive.folders, list.folders),
      for (final MapEntry(:key, :value) in foldersRefused.entries)
        FolderWriteRefused(key, value),
    ],
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

Future<_OneCheck> _checkOne(LibraryStore store, StrategyData expected) async {
  final id = expected.id;
  switch (strategyToRows(expected)) {
    case StrategyRowsRefused(:final problems):
      return _Checked([StrategyNotConverted(id, problems)]);
    case StrategyRowsMade(:final rows):
      return switch (rowTextsOf(rows)) {
        final RowsNotText notText =>
          _Checked([StrategyRowsNotEncodable(id, notText)]),
        RowsAsText(rows: final texts) =>
          await _compared(store, expected, texts),
      };
  }
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
  switch (rowTextsOf(storedRows)) {
    case final RowsNotText notText:
      return _Checked([StrategyRowsNotEncodable(id, notText)]);
    case RowsAsText(rows: final texts):
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
            FolderMade() => switch (
                  _differingFields(folderToRow(folder), row)) {
                [] => FolderSame(folder.id),
                final fields => FolderDiffers(folder.id, fields),
              },
          },
      },
    for (final row in stored)
      if (!hiveIds.contains(row.publicId)) FolderNotInHive(row.publicId),
  ];
}

List<String> _differingFields(ReadableFolder expected, ReadableFolder actual) {
  final left = expected.toJsonView();
  final right = actual.toJsonView();
  String? text(Object? value) => switch (encodeJson(value)) {
        Encoded(:final text) => text,
        NotEncoded() => null,
      };
  return [
    for (final key in {...left.keys, ...right.keys})
      if (!left.containsKey(key) ||
          !right.containsKey(key) ||
          text(left[key]) != text(right[key]))
        key,
  ]..sort();
}
