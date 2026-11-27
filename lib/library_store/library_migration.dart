import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/folder_as_row.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/canvas_units.dart';
import 'package:icarus/migrations/hidden_folder_repair.dart';
import 'package:icarus/providers/action_history_models.dart';
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

const storeHoldsALibrary =
    'the store already holds a library and has no record of a copy';

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
  final bool resuming;
  switch (store.migration) {
    case final MigrationFinished record:
      return MigrationWasFinished(record);
    case MigrationUnreadable(:final problem):
      return MigrationRecordUnreadable(problem);
    case MigrationCopying():
      resuming = true;
    case MigrationNotStarted():
      resuming = false;
  }
  final LibraryList list;
  switch (store.library) {
    case LibraryOpen(list: final open):
      list = open;
    case LibraryShut(:final failure):
      return MigrationStopped(failure);
  }
  if (!resuming && _holdsALibrary(list)) {
    return const MigrationNotRun(storeHoldsALibrary);
  }
  final startedAt = clock();
  if (_stopped(await store.recordMigration(MigrationCopying(startedAt)))
      case final failure?) {
    return MigrationStopped(failure);
  }
  if (resuming) {
    if (await _emptied(store, list) case final notEmptied?) return notEmptied;
  }

  final foldersLeft = <LeftBehind>[];
  final folderIds = <String>{};
  for (final folder in folders) {
    if (!folderIds.add(folder.id)) {
      foldersLeft.add(LeftBehind(folder.id, folder.name, sameIdTwice));
    }
  }
  final orphanFolders =
      foldersUnderMissingParents(folders, folderIds.contains).toSet();
  for (final folder
      in foldersParentsFirst(_firstOfEachId(folders, (folder) => folder.id))) {
    final atItsPlace = orphanFolders.contains(folder)
        ? _folderAtTopLevel(folder)
        : folder;
    switch (_put(await store.editLibrary([
      PutFolder(folderToRow(atItsPlace)),
    ]))) {
      case _Kept():
        break;
      case _LeftBehind(:final reason):
        foldersLeft.add(LeftBehind(folder.id, folder.name, reason));
      case _StoreStopped(:final failure):
        return MigrationStopped(failure);
    }
  }

  final orphanStrategies =
      strategiesInMissingFolders(strategies, folderIds.contains).toSet();
  final strategiesLeft = <LeftBehind>[];
  final strategyIds = <String>{};
  for (final strategy in strategies) {
    if (!strategyIds.add(strategy.id)) {
      strategiesLeft.add(LeftBehind(strategy.id, strategy.name, sameIdTwice));
      continue;
    }
    final copy = wholeCopyOf(strategy);
    if (orphanStrategies.contains(strategy)) copy.folderID = null;
    final StrategyRowSet rows;
    switch (await _rowsOf(copy)) {
      case _Converted(rows: final made):
        rows = made;
      case _NotConverted(:final problem):
        strategiesLeft.add(LeftBehind(strategy.id, strategy.name, problem));
        continue;
    }
    switch (_put(await store.putStrategy(
      rows,
      writtenAt: Settings.versionNumber,
    ))) {
      case _Kept():
        break;
      case _LeftBehind(:final reason):
        strategiesLeft.add(LeftBehind(strategy.id, strategy.name, reason));
      case _StoreStopped(:final failure):
        return MigrationStopped(failure);
    }
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
    current = await StrategyMigrator.migrateLegacyData(strategy);
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

bool _holdsALibrary(LibraryList list) =>
    list.strategies.any((summary) => summary.sync is KeptHere) ||
    list.unreadableStrategies.isNotEmpty ||
    list.folders.isNotEmpty;

Future<LibraryMigration?> _emptied(
  LibraryStore store,
  LibraryList list,
) async {
  final changes = [
    for (final summary in list.strategies)
      if (summary.sync is KeptHere) RemoveStrategy(summary.publicId),
    for (final row in folderRowsChildrenFirst([
      for (final row in list.folders)
        if (row is ReadableFolder) row,
    ]))
      RemoveFolder(row.publicId),
  ];
  if (changes.isEmpty) return null;
  return switch (await store.editLibrary(changes)) {
    Saved() || NothingToSave() => null,
    Refused(:final reason) =>
      MigrationNotRun('the store could not be emptied for the copy: $reason'),
    NotSaved(:final failure) ||
    SaveInDoubt(:final failure) =>
      MigrationStopped(failure),
  };
}

Folder _folderAtTopLevel(Folder folder) => Folder(
      name: folder.name,
      id: folder.id,
      dateCreated: folder.dateCreated,
      iconId: folder.iconId,
      color: folder.color,
      customColor: folder.customColor,
    );

StrategyData wholeCopyOf(StrategyData strategy) =>
    cloneStrategy(strategy).copyWith(
      agentData: [
        // ignore: deprecated_member_use_from_same_package
        for (final agent in strategy.agentData)
          clonePlacedAgentNode(agent) as PlacedAgent,
      ],
      abilityData: [
        // ignore: deprecated_member_use_from_same_package
        for (final ability in strategy.abilityData)
          clonePlacedAbility(ability),
      ],
      drawingData: [
        // ignore: deprecated_member_use_from_same_package
        for (final drawing in strategy.drawingData)
          cloneDrawingElement(drawing),
      ],
      textData: [
        // ignore: deprecated_member_use_from_same_package
        for (final text in strategy.textData)
          clonePlacedText(text),
      ],
      imageData: [
        // ignore: deprecated_member_use_from_same_package
        for (final image in strategy.imageData)
          clonePlacedImage(image),
      ],
      utilityData: [
        // ignore: deprecated_member_use_from_same_package
        for (final utility in strategy.utilityData)
          clonePlacedUtility(utility),
      ],
      // ignore: deprecated_member_use_from_same_package
      strategySettings: cloneSettings(strategy.strategySettings),
    );

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
