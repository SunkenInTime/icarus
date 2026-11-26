import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/folder_as_row.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/canvas_units.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

sealed class LibraryMigration {
  const LibraryMigration();
}

final class MigrationWasFinished extends LibraryMigration {
  const MigrationWasFinished(this.record);

  final MigrationFinished record;
}

final class MigrationFinishedNow extends LibraryMigration {
  const MigrationFinishedNow(this.record);

  final MigrationFinished record;
}

final class MigrationStopped extends LibraryMigration {
  const MigrationStopped(this.failure);

  final StorageFailure failure;
}

final class MigrationRecordUnreadable extends LibraryMigration {
  const MigrationRecordUnreadable(this.problem);

  final String problem;
}

final class MigrationNotRun extends LibraryMigration {
  const MigrationNotRun(this.why);

  final String why;
}

const sameIdTwice = 'another one in this library has the same id';

sealed class _Put {
  const _Put();
}

final class _Kept extends _Put {
  const _Kept();
}

final class _LeftBehind extends _Put {
  const _LeftBehind(this.reason);

  final String reason;
}

final class _StoreStopped extends _Put {
  const _StoreStopped(this.failure);

  final StorageFailure failure;
}

_Put _put(LibraryEditResult result) => switch (result) {
      Saved() || NothingToSave() => const _Kept(),
      Refused(:final reason) => _LeftBehind('the store refused it: $reason'),
      NotSaved(failure: final WouldNotReadBack failure) =>
        _LeftBehind('it would not read back: $failure'),
      NotSaved(:final failure) ||
      SaveInDoubt(:final failure) =>
        _StoreStopped(failure),
    };

Future<LibraryMigration> migrateLibraryIntoStore(
  LibraryStore store, {
  required List<StrategyData> strategies,
  required List<Folder> folders,
  DateTime Function() clock = _now,
}) async {
  switch (store.migration) {
    case final MigrationFinished record:
      return MigrationWasFinished(record);
    case MigrationUnreadable(:final problem):
      return MigrationRecordUnreadable(problem);
    case MigrationNotStarted() || MigrationCopying():
      break;
  }
  final startedAt = clock();
  if (_stopped(await store.recordMigration(MigrationCopying(startedAt)))
      case final failure?) {
    return MigrationStopped(failure);
  }

  final LibraryList list;
  switch (store.library) {
    case LibraryOpen(list: final open):
      list = open;
    case LibraryShut(:final failure):
      return MigrationStopped(failure);
  }
  final stored = {for (final row in list.folders) row.publicId: row};
  final foldersLeft = <LeftBehind>[];
  final folderIds = <String>{};
  for (final folder in folders) {
    if (!folderIds.add(folder.id)) {
      foldersLeft.add(LeftBehind(folder.id, folder.name, sameIdTwice));
    }
  }
  for (final folder
      in foldersParentsFirst(_firstOfEachId(folders, (folder) => folder.id))) {
    switch (_put(await store.editLibrary([
      PutFolder(folderRowOf(folder, stored[folder.id])),
    ]))) {
      case _Kept():
        break;
      case _LeftBehind(:final reason):
        foldersLeft.add(LeftBehind(folder.id, folder.name, reason));
      case _StoreStopped(:final failure):
        return MigrationStopped(failure);
    }
  }

  final strategiesLeft = <LeftBehind>[];
  final strategyIds = <String>{};
  for (final strategy in strategies) {
    if (!strategyIds.add(strategy.id)) {
      strategiesLeft.add(LeftBehind(strategy.id, strategy.name, sameIdTwice));
      continue;
    }
    final StrategyRowSet rows;
    switch (await _rowsOf(strategy)) {
      case _Converted(rows: final made):
        rows = made;
      case _NotConverted(:final problem):
        strategiesLeft.add(LeftBehind(strategy.id, strategy.name, problem));
        continue;
    }
    switch (_put(await store.putStrategy(rows))) {
      case _Kept():
        break;
      case _LeftBehind(:final reason):
        strategiesLeft.add(LeftBehind(strategy.id, strategy.name, reason));
      case _StoreStopped(:final failure):
        return MigrationStopped(failure);
    }
  }

  if (await _removeWhatHiveDoesNotHold(store, list, strategies, folders)
      case final failure?) {
    return MigrationStopped(failure);
  }

  final record = MigrationFinished(
    startedAt: startedAt,
    finishedAt: clock(),
    strategies: strategiesLeft,
    folders: foldersLeft,
  );
  if (_stopped(await store.recordMigration(record)) case final failure?) {
    return MigrationStopped(failure);
  }
  return MigrationFinishedNow(record);
}

DateTime _now() => DateTime.now().toUtc();

List<T> _firstOfEachId<T>(List<T> items, String Function(T item) idOf) {
  final seen = <String>{};
  return [
    for (final item in items)
      if (seen.add(idOf(item))) item,
  ];
}

StorageFailure? _stopped(MigrationRecordResult result) => switch (result) {
      Saved() || NothingToSave() || Refused() => null,
      NotSaved(:final failure) || SaveInDoubt(:final failure) => failure,
    };

sealed class _Rows {
  const _Rows();
}

final class _Converted extends _Rows {
  const _Converted(this.rows);

  final StrategyRowSet rows;
}

final class _NotConverted extends _Rows {
  const _NotConverted(this.problem);

  final String problem;
}

Future<_Rows> _rowsOf(StrategyData strategy) async {
  final StrategyData current;
  try {
    current = await StrategyMigrator.migrateLegacyData(cloneStrategy(strategy));
  } on Object catch (error) {
    return _NotConverted('it could not be brought up to date: $error');
  }
  return switch (strategyToRows(pagesInTheirShownOrder(current))) {
    StrategyRowsMade(:final rows) => _Converted(rows),
    StrategyRowsRefused(:final problems) => _NotConverted(
        'it could not be converted: ${problems.map(rowsProblemWords).join('; ')}',
      ),
  };
}

StrategyData pagesInTheirShownOrder(StrategyData strategy) {
  final positions = {for (final page in strategy.pages) page.sortIndex};
  if (positions.length == strategy.pages.length) return strategy;
  final shown = [...strategy.pages.indexed]..sort((a, b) {
      final byPosition = a.$2.sortIndex.compareTo(b.$2.sortIndex);
      return byPosition != 0 ? byPosition : a.$1.compareTo(b.$1);
    });
  return strategy.copyWith(pages: [
    for (final (position, (_, page)) in shown.indexed)
      page.copyWith(sortIndex: position),
  ]);
}

Future<StorageFailure?> _removeWhatHiveDoesNotHold(
  LibraryStore store,
  LibraryList before,
  List<StrategyData> strategies,
  List<Folder> folders,
) async {
  final inHive = {for (final strategy in strategies) strategy.id};
  for (final summary in before.strategies) {
    if (summary.sync is! KeptHere || inHive.contains(summary.publicId)) {
      continue;
    }
    switch (await store.editLibrary([RemoveStrategy(summary.publicId)])) {
      case NotSaved(:final failure) || SaveInDoubt(:final failure):
        return failure;
      case Saved() || NothingToSave() || Refused():
        break;
    }
  }
  final foldersInHive = {for (final folder in folders) folder.id};
  for (final row in folderRowsChildrenFirst([
    for (final row in before.folders)
      if (!foldersInHive.contains(row.publicId)) row,
  ])) {
    switch (await store.editLibrary([RemoveFolder(row.publicId)])) {
      case NotSaved(:final failure) || SaveInDoubt(:final failure):
        return failure;
      case Saved() || NothingToSave() || Refused():
        break;
    }
  }
  return null;
}

ReadableFolder folderRowOf(Folder folder, FolderRow? stored) {
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

List<Folder> foldersParentsFirst(List<Folder> folders) {
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

List<FolderRow> folderRowsChildrenFirst(List<FolderRow> folders) {
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

String rowsProblemWords(RowsProblem problem) => switch (problem) {
      NotMigrated(:final versionNumber) =>
        'it was saved by version $versionNumber and never brought up to date',
      WrittenByNewerBuild(:final versionNumber) =>
        'it was saved by a newer version of Icarus ($versionNumber)',
      ContentOutsidePages(:final items) =>
        '$items items are saved outside any page',
      PaletteHasTransparency() => 'its map colours are partly transparent',
      PageIdRepeated(:final pageId) => 'two of its pages share the id $pageId',
      ItemNotJson(:final pageId, :final kind, :final itemId, :final problem) =>
        'the ${kind.name} $itemId on page $pageId cannot be written: $problem',
      LineupIdRepeated(:final pageId, :final part, :final id) =>
        'the lineup ${part.name} $id is on page $pageId twice',
      LineupNotJson(:final pageId, :final problem) =>
        'a lineup on page $pageId cannot be written: $problem',
      LineupMissingEnd(:final pageId, :final linkId) =>
        'the lineup $linkId on page $pageId has lost one of its ends',
      LineupSpotUnaimed(:final pageId, :final part, :final spotId) =>
        'the lineup ${part.name} $spotId on page $pageId belongs to no lineup',
      CarriedRowOffPage(:final elementId, :final pageId) =>
        'the item $elementId is carried off page $pageId',
    };
