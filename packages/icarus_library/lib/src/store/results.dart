import '../outcome.dart';
import '../rows.dart';
import '../strategy_rows.dart';
import 'engine.dart';
import 'stored_row.dart';
import 'summary.dart';

sealed class Saving<S, R> {
  const Saving();
}

final class Saved<S, R> extends Saving<S, R> {
  const Saved(this.value);

  final S value;
}

final class NothingToSave<S, R> extends Saving<S, R> {
  const NothingToSave();
}

final class Refused<S, R> extends Saving<S, R> {
  const Refused(this.reason);

  final R reason;
}

final class NotSaved<S, R> extends Saving<S, R> {
  const NotSaved(this.failure);

  final StorageFailure failure;
}

final class SaveInDoubt<S, R> extends Saving<S, R> {
  const SaveInDoubt(this.failure);

  final StorageFailure failure;
}

typedef CommitResult = Saving<StrategyEdited, CommitRefusal>;

typedef LibraryEditResult = Saving<LibraryEdited, LibraryRefusal>;

typedef RebuildResult = Saving<StrategySummary, CommitRefusal>;

sealed class CommitRefusal {
  const CommitRefusal();
}

sealed class LibraryRefusal {
  const LibraryRefusal();
}

final class OpRefusal extends CommitRefusal {
  const OpRefusal(this.refusal);

  final Refusal refusal;

  @override
  String toString() => 'OpRefusal($refusal)';
}

final class NoSuchStrategy implements CommitRefusal, LibraryRefusal {
  const NoSuchStrategy(this.strategyPublicId);

  final String strategyPublicId;

  @override
  String toString() => 'NoSuchStrategy($strategyPublicId)';
}

final class UnreadableRowInTheWay implements CommitRefusal, LibraryRefusal {
  const UnreadableRowInTheWay(this.row);

  final UnreadableRow row;

  @override
  String toString() => 'UnreadableRowInTheWay(${row.area} ${row.key})';
}

final class StrategyAlreadyInStore extends LibraryRefusal {
  const StrategyAlreadyInStore(this.strategyPublicId);

  final String strategyPublicId;

  @override
  String toString() => 'StrategyAlreadyInStore($strategyPublicId)';
}

final class NoSuchFolder extends LibraryRefusal {
  const NoSuchFolder(this.folderPublicId);

  final String folderPublicId;

  @override
  String toString() => 'NoSuchFolder($folderPublicId)';
}

final class FolderNotEmpty extends LibraryRefusal {
  const FolderNotEmpty(this.folderPublicId);

  final String folderPublicId;

  @override
  String toString() => 'FolderNotEmpty($folderPublicId)';
}

final class FolderInsideItself extends LibraryRefusal {
  const FolderInsideItself(this.folderPublicId);

  final String folderPublicId;

  @override
  String toString() => 'FolderInsideItself($folderPublicId)';
}

sealed class StoreChange {
  const StoreChange();
}

final class StrategyEdited extends StoreChange {
  StrategyEdited({
    required this.strategyPublicId,
    required List<RowWrite> writes,
    required this.undo,
    required this.summary,
  }) : writes = List.unmodifiable(writes);

  final String strategyPublicId;
  final List<RowWrite> writes;
  final Undo undo;
  final StrategySummary summary;
}

final class LibraryEdited extends StoreChange {
  LibraryEdited({
    required List<StrategySummary> summaries,
    required List<String> removedStrategies,
    required List<FolderRow> folders,
    required List<String> removedFolders,
  }) : summaries = List.unmodifiable(summaries),
       removedStrategies = List.unmodifiable(removedStrategies),
       folders = List.unmodifiable(folders),
       removedFolders = List.unmodifiable(removedFolders);

  final List<StrategySummary> summaries;
  final List<String> removedStrategies;
  final List<FolderRow> folders;
  final List<String> removedFolders;
}

sealed class Reading<T> {
  const Reading();
}

final class Found<T> extends Reading<T> {
  const Found(this.value);

  final T value;
}

final class NotFound<T> extends Reading<T> {
  const NotFound();
}

final class Unreadable<T> extends Reading<T> {
  const Unreadable(this.row);

  final UnreadableRow row;
}

final class NotRead<T> extends Reading<T> {
  const NotRead(this.failure);

  final StorageFailure failure;
}

final class StrategyContent {
  StrategyContent({
    required this.strategy,
    required List<PageRow> pages,
    required Map<String, PageSettingsRow> settings,
    required List<UnreadableRow> unreadable,
  }) : pages = List.unmodifiable(pages),
       settings = Map.unmodifiable(settings),
       unreadable = List.unmodifiable(unreadable);

  final StrategyRow strategy;
  final List<PageRow> pages;
  final Map<String, PageSettingsRow> settings;
  final List<UnreadableRow> unreadable;
}

final class PageContent {
  PageContent({
    required this.page,
    required this.settings,
    required List<ElementRow> elements,
    required List<LineupGroupRow> lineupGroups,
    required List<UnreadableRow> unreadable,
  }) : elements = List.unmodifiable(elements),
       lineupGroups = List.unmodifiable(lineupGroups),
       unreadable = List.unmodifiable(unreadable);

  final PageRow page;
  final PageSettingsRow? settings;
  final List<ElementRow> elements;
  final List<LineupGroupRow> lineupGroups;
  final List<UnreadableRow> unreadable;
}

final class LibraryList {
  LibraryList({
    required List<StrategySummary> strategies,
    required List<FolderRow> folders,
    required List<UnreadableRow> unreadable,
  }) : strategies = List.unmodifiable(strategies),
       folders = List.unmodifiable(folders),
       unreadable = List.unmodifiable(unreadable);

  final List<StrategySummary> strategies;
  final List<FolderRow> folders;
  final List<UnreadableRow> unreadable;
}

sealed class LibraryChange {
  const LibraryChange();
}

final class AddStrategy extends LibraryChange {
  const AddStrategy(
    this.rows, {
    required this.createdAt,
    required this.updatedAt,
  });

  final StrategyRowSet rows;
  final DateTime createdAt;
  final DateTime updatedAt;
}

final class RemoveStrategy extends LibraryChange {
  const RemoveStrategy(this.strategyPublicId);

  final String strategyPublicId;
}

final class MoveStrategy extends LibraryChange {
  const MoveStrategy(this.strategyPublicId, this.folderPublicId);

  final String strategyPublicId;
  final String? folderPublicId;
}

final class PutFolder extends LibraryChange {
  const PutFolder(this.folder);

  final FolderRow folder;
}

final class RemoveFolder extends LibraryChange {
  const RemoveFolder(this.folderPublicId);

  final String folderPublicId;
}

sealed class OpenProblem {
  const OpenProblem();
}

final class OpenStorageFailed extends OpenProblem {
  const OpenStorageFailed(this.failure);

  final StorageFailure failure;

  @override
  String toString() => 'OpenStorageFailed($failure)';
}

final class SavedEditUnreadable extends OpenProblem {
  const SavedEditUnreadable(this.text, this.problem);

  final String text;
  final String problem;

  @override
  String toString() => 'SavedEditUnreadable($problem)';
}
