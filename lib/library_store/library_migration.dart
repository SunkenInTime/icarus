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
  const MigrationFinishedNow(this.record, {this.took = const CopyTook()});

  final MigrationFinished record;
  final CopyTook took;
}

final class CopyTook {
  const CopyTook({
    this.copying = Duration.zero,
    this.upgrading = Duration.zero,
    this.converting = Duration.zero,
    this.committing = Duration.zero,
    this.commits = 0,
  });

  final Duration copying;
  final Duration upgrading;
  final Duration converting;
  final Duration committing;
  final int commits;
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

  final copying = Stopwatch();
  final upgrading = Stopwatch();
  final converting = Stopwatch();
  final committing = Stopwatch();
  var commits = 0;
  Future<T> committed<T>(Future<T> Function() commit) async {
    commits++;
    committing.start();
    try {
      return await commit();
    } finally {
      committing.stop();
    }
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
  final folderPuts = [
    for (final folder in foldersParentsFirst(
      _firstOfEachId(folders, (folder) => folder.id),
    ))
      _Ready(
        folder.id,
        folder.name,
        PutFolder(folderToRow(
          orphanFolders.contains(folder) ? _folderAtTopLevel(folder) : folder,
        )),
      ),
  ];
  if (await _putInBatches(store, folderPuts, foldersLeft, committed)
      case final failure?) {
    return MigrationStopped(failure);
  }

  final orphanStrategies =
      strategiesInMissingFolders(strategies, folderIds.contains).toSet();
  final strategiesLeft = <LeftBehind>[];
  final strategyIds = <String>{};
  var batch = <_Copied>[];
  for (final strategy in strategies) {
    if (!strategyIds.add(strategy.id)) {
      batch.add(_NotCopied(LeftBehind(strategy.id, strategy.name, sameIdTwice)));
      continue;
    }
    copying.start();
    final copy = wholeCopyOf(strategy);
    copying.stop();
    if (orphanStrategies.contains(strategy)) copy.folderID = null;
    switch (await _rowsOf(copy, upgrading, converting)) {
      case _Converted(:final rows):
        batch.add(_Ready(
          strategy.id,
          strategy.name,
          AddStrategy(rows, writtenAt: Settings.versionNumber),
        ));
      case _NotConverted(:final problem):
        batch.add(
          _NotCopied(LeftBehind(strategy.id, strategy.name, problem)),
        );
    }
    if (batch.length == strategiesPerCommit) {
      if (await _putInBatches(store, batch, strategiesLeft, committed)
          case final failure?) {
        return MigrationStopped(failure);
      }
      batch = [];
    }
  }
  if (await _putInBatches(store, batch, strategiesLeft, committed)
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
  return MigrationFinishedNow(
    record,
    took: CopyTook(
      copying: copying.elapsed,
      upgrading: upgrading.elapsed,
      converting: converting.elapsed,
      committing: committing.elapsed,
      commits: commits,
    ),
  );
}

DateTime _now() => DateTime.now().toUtc();

const strategiesPerCommit = 100;

sealed class _Copied {
  const _Copied();
}

final class _Ready extends _Copied {
  const _Ready(this.id, this.name, this.change);

  final String id;
  final String name;
  final LibraryChange change;
}

final class _NotCopied extends _Copied {
  const _NotCopied(this.left);

  final LeftBehind left;
}

Future<StorageFailure?> _putInBatches(
  LibraryStore store,
  List<_Copied> batch,
  List<LeftBehind> left,
  Future<LibraryEditResult> Function(Future<LibraryEditResult> Function())
      committed,
) async {
  final ready = batch.whereType<_Ready>().toList();
  if (ready.isEmpty) {
    left.addAll([for (final copied in batch) (copied as _NotCopied).left]);
    return null;
  }
  switch (_put(await committed(
    () => store.editLibrary([for (final each in ready) each.change]),
  ))) {
    case _Kept():
      left.addAll([
        for (final copied in batch)
          if (copied case _NotCopied(left: final one)) one,
      ]);
      return null;
    case _LeftBehind():
      break;
    case _StoreStopped(:final failure):
      return failure;
  }
  for (final copied in batch) {
    switch (copied) {
      case _NotCopied(left: final one):
        left.add(one);
      case _Ready(:final id, :final name, :final change):
        switch (_put(await committed(() => _putOne(store, change)))) {
          case _Kept():
            break;
          case _LeftBehind(:final reason):
            left.add(LeftBehind(id, name, reason));
          case _StoreStopped(:final failure):
            return failure;
        }
    }
  }
  return null;
}

Future<LibraryEditResult> _putOne(LibraryStore store, LibraryChange change) =>
    switch (change) {
      AddStrategy(:final rows, :final writtenAt) =>
        store.putStrategy(rows, writtenAt: writtenAt),
      _ => store.editLibrary([change]),
    };

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

Future<_Rows> _rowsOf(
  StrategyData strategy,
  Stopwatch upgrading,
  Stopwatch converting,
) async {
  final StrategyData current;
  upgrading.start();
  try {
    current = await StrategyMigrator.migrateLegacyData(strategy);
  } on Object catch (error) {
    return _NotConverted('it could not be brought up to date: $error');
  } finally {
    upgrading.stop();
  }
  converting.start();
  final made = strategyToRows(pagesInTheirShownOrder(current));
  converting.stop();
  return switch (made) {
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
