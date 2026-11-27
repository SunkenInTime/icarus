import 'dart:collection' show UnmodifiableMapView;

import '../outcome.dart';
import '../rows.dart';
import '../strategy_rows.dart';
import '../cloud/account.dart';
import '../cloud/queue.dart';
import '../cloud/sync.dart';
import '../cloud/version.dart';
import '../undo.dart';
import 'engine.dart';
import 'layout.dart';
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

typedef CommitResult = Saving<Committed, CommitRefusal>;

typedef BatchResult = Saving<List<Committed>, CommitRefusal>;

typedef LibraryEditResult = Saving<LibraryEdited, LibraryRefusal>;

typedef RebuildResult = Saving<StrategySummary, CommitRefusal>;

final class Committed {
  const Committed({required this.change, required this.undo});

  final StrategyEdited change;
  final Undo undo;
}

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

  final Row row;

  @override
  String toString() => 'UnreadableRowInTheWay(${row.key})';
}

final class StoredRowsDisagree implements CommitRefusal, LibraryRefusal {
  const StoredRowsDisagree(
    this.reason, {
    this.serial = 0,
    this.strategyPublicId,
  });

  final String reason;
  final int serial;
  final String? strategyPublicId;

  @override
  String toString() =>
      'StoredRowsDisagree: the rows stored for it disagree with its queue: '
      '$reason';
}

final class UnplacedRowInTheWay implements CommitRefusal, LibraryRefusal {
  const UnplacedRowInTheWay(this.ref);

  final StoredRowRef ref;

  @override
  String toString() => 'UnplacedRowInTheWay($ref)';
}

final class StrategyNotReadable implements CommitRefusal, LibraryRefusal {
  const StrategyNotReadable(this.ref);

  final StrategyRef ref;

  @override
  String toString() => 'StrategyNotReadable($ref)';
}

final class QueueRefusal extends CommitRefusal {
  const QueueRefusal(this.why);

  final Inapplicable why;

  @override
  String toString() => 'QueueRefusal($why)';
}

final class UnreadableQueueRow {
  const UnreadableQueueRow(this.ref, this.problem);

  final StoredRowRef ref;
  final String problem;

  @override
  bool operator ==(Object other) =>
      other is UnreadableQueueRow &&
      other.ref == ref &&
      other.problem == problem;

  @override
  int get hashCode => Object.hash(ref, problem);

  @override
  String toString() => 'UnreadableQueueRow($ref, $problem)';
}

final class QueueHeld implements CommitRefusal, LibraryRefusal {
  QueueHeld(List<UnreadableQueueRow> rows) : rows = List.unmodifiable(rows);

  final List<UnreadableQueueRow> rows;

  @override
  String toString() => 'QueueHeld($rows)';
}

final class ResultOutOfPlace implements CommitRefusal, LibraryRefusal {
  const ResultOutOfPlace(this.key);

  final RowKey key;

  @override
  bool operator ==(Object other) =>
      other is ResultOutOfPlace && other.key == key;

  @override
  int get hashCode => Object.hash(ResultOutOfPlace, key);

  @override
  String toString() => 'ResultOutOfPlace($key)';
}

final class EditOfAReplacedStrategy implements CommitRefusal {
  EditOfAReplacedStrategy(this.strategyPublicId, List<String> opIds)
    : opIds = List.unmodifiable(opIds);

  final String strategyPublicId;
  final List<String> opIds;

  @override
  String toString() =>
      'EditOfAReplacedStrategy($strategyPublicId, ${opIds.join(', ')})';
}

final class ResultWithoutLife implements CommitRefusal, LibraryRefusal {
  const ResultWithoutLife(this.key);

  final RowKey key;

  @override
  bool operator ==(Object other) =>
      other is ResultWithoutLife && other.key == key;

  @override
  int get hashCode => Object.hash(ResultWithoutLife, key);

  @override
  String toString() => 'ResultWithoutLife($key)';
}

final class QueueNotHeld implements CommitRefusal {
  const QueueNotHeld(this.strategyPublicId);

  final String strategyPublicId;

  @override
  bool operator ==(Object other) =>
      other is QueueNotHeld && other.strategyPublicId == strategyPublicId;

  @override
  int get hashCode => Object.hash(QueueNotHeld, strategyPublicId);

  @override
  String toString() => 'QueueNotHeld($strategyPublicId)';
}

final class NumbersUnreadable implements CommitRefusal, LibraryRefusal {
  const NumbersUnreadable();

  @override
  bool operator ==(Object other) => other is NumbersUnreadable;

  @override
  int get hashCode => (NumbersUnreadable).hashCode;

  @override
  String toString() => 'NumbersUnreadable';
}

final class CopyNeedsContent implements CommitRefusal {
  const CopyNeedsContent(this.pagePublicId);

  final String pagePublicId;

  @override
  bool operator ==(Object other) =>
      other is CopyNeedsContent && other.pagePublicId == pagePublicId;

  @override
  int get hashCode => Object.hash(CopyNeedsContent, pagePublicId);

  @override
  String toString() => 'CopyNeedsContent($pagePublicId)';
}

final class UnsentWorkInArea extends LibraryRefusal {
  const UnsentWorkInArea(this.ref);

  final StrategyRef ref;

  @override
  String toString() => 'UnsentWorkInArea($ref)';
}

final class DiscardsUnsentWork {
  const DiscardsUnsentWork();
}

final class NotACloudStrategy extends CommitRefusal {
  const NotACloudStrategy(this.strategyPublicId);

  final String strategyPublicId;

  @override
  String toString() => 'NotACloudStrategy($strategyPublicId)';
}

final class WorkOfAnotherAccount implements CommitRefusal, LibraryRefusal {
  const WorkOfAnotherAccount(this.strategyPublicId, this.owner);

  final String strategyPublicId;
  final CloudOwner owner;

  @override
  String toString() => 'WorkOfAnotherAccount($strategyPublicId, $owner)';
}

final class OwnerNotRead extends CommitRefusal {
  const OwnerNotRead(this.strategyPublicId);

  final String strategyPublicId;

  @override
  String toString() => 'OwnerNotRead($strategyPublicId)';
}

final class AccountNeeded extends CommitRefusal {
  const AccountNeeded(this.strategyPublicId);

  final String strategyPublicId;

  @override
  String toString() => 'AccountNeeded($strategyPublicId)';
}

final class KeptInTheCloud extends LibraryRefusal {
  const KeptInTheCloud(this.strategyPublicId);

  final String strategyPublicId;

  @override
  String toString() => 'KeptInTheCloud($strategyPublicId)';
}

final class CloudWorkOutstanding extends LibraryRefusal {
  const CloudWorkOutstanding(this.strategyPublicId, this.tally);

  final String strategyPublicId;
  final Tally tally;

  @override
  String toString() => 'CloudWorkOutstanding($strategyPublicId, $tally)';
}

final class CopyLeavesRowsBehind extends CommitRefusal {
  const CopyLeavesRowsBehind(this.pagePublicId);

  final String pagePublicId;

  @override
  String toString() => 'CopyLeavesRowsBehind($pagePublicId)';
}

final class NoSuchUnreadableStrategy extends LibraryRefusal {
  const NoSuchUnreadableStrategy(this.ref);

  final StrategyRef ref;

  @override
  String toString() => 'NoSuchUnreadableStrategy($ref)';
}

final class FolderLoop extends LibraryRefusal {
  FolderLoop(List<String> folders) : folders = List.unmodifiable(folders);

  final List<String> folders;

  @override
  String toString() => 'FolderLoop($folders)';
}

final class StrategyAlreadyInStore extends LibraryRefusal {
  const StrategyAlreadyInStore(this.strategyPublicId);

  final String strategyPublicId;

  @override
  String toString() => 'StrategyAlreadyInStore($strategyPublicId)';
}

final class RowOutsideStrategy extends LibraryRefusal {
  const RowOutsideStrategy(this.key);

  final RowKey key;

  @override
  String toString() => 'RowOutsideStrategy($key)';
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

enum Dropped {
  trashedPage,
  tombstone,
  unknownKind,
  foreignName,
  unknownField,
  duplicateRow,
}

final class PutWouldDrop extends LibraryRefusal {
  const PutWouldDrop(this.ref, this.dropped);

  final StoredRowRef ref;
  final Dropped dropped;
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
    required this.opId,
    required List<RowWrite> writes,
    required List<RowKey> removed,
    required this.summary,
  }) : writes = List.unmodifiable(writes),
       removed = List.unmodifiable(removed);

  final String strategyPublicId;
  final String opId;
  final List<RowWrite> writes;
  final List<RowKey> removed;
  final StrategySummary summary;
}

final class StrategyRefreshed extends StoreChange {
  const StrategyRefreshed({
    required this.strategyPublicId,
    required this.summary,
  });

  final String strategyPublicId;
  final StrategySummary summary;
}

final class StrategyRefused extends StoreChange {
  const StrategyRefused({
    required this.strategyPublicId,
    required this.refusal,
  });

  final String strategyPublicId;
  final StoredRowsDisagree refusal;
}

final class StoredResultsDropped extends StoreChange {
  const StoredResultsDropped({
    required this.strategyPublicId,
    required this.group,
    required this.problem,
  });

  final String strategyPublicId;
  final String group;
  final String problem;

  @override
  bool operator ==(Object other) =>
      other is StoredResultsDropped &&
      other.strategyPublicId == strategyPublicId &&
      other.group == group &&
      other.problem == problem;

  @override
  int get hashCode => Object.hash(strategyPublicId, group, problem);

  @override
  String toString() =>
      'StoredResultsDropped($strategyPublicId: $group could not be read: '
      '$problem)';
}

final class LibraryEdited extends StoreChange {
  LibraryEdited({
    required List<StrategySummary> summaries,
    required List<String> removedStrategies,
    required List<StrategyRef> removedUnreadableStrategies,
    required List<FolderRow> folders,
    required List<String> removedFolders,
  }) : summaries = List.unmodifiable(summaries),
       removedStrategies = List.unmodifiable(removedStrategies),
       removedUnreadableStrategies = List.unmodifiable(
         removedUnreadableStrategies,
       ),
       folders = List.unmodifiable(folders),
       removedFolders = List.unmodifiable(removedFolders);

  final List<StrategySummary> summaries;
  final List<String> removedStrategies;
  final List<StrategyRef> removedUnreadableStrategies;
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

final class NotRead<T> extends Reading<T> {
  const NotRead(this.failure);

  final StorageFailure failure;
}

final class InUnreadableStrategy<T> extends Reading<T> {
  const InUnreadableStrategy(this.listing);

  final UnreadableStrategyListing listing;
}

sealed class Unloading {
  const Unloading();
}

final class Unloaded extends Unloading {
  const Unloaded();
}

final class NotUnloaded extends Unloading {
  const NotUnloaded(this.failure);

  final StorageFailure failure;
}

final class StoredRowRef {
  const StoredRowRef(this.area, this.name);

  final String area;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is StoredRowRef && other.area == area && other.name == name;

  @override
  int get hashCode => Object.hash(area, name);

  @override
  String toString() => 'StoredRowRef($area, $name)';
}

final class StrategyRef {
  const StrategyRef(this.area);

  final String area;

  @override
  bool operator ==(Object other) => other is StrategyRef && other.area == area;

  @override
  int get hashCode => area.hashCode;

  @override
  String toString() => 'StrategyRef($area)';
}

final class UnplacedRow {
  const UnplacedRow({
    required this.ref,
    required this.stored,
    required this.problem,
  });

  final StoredRowRef ref;
  final Object? stored;
  final String problem;
}

final class UnreadableStrategyListing {
  const UnreadableStrategyListing({
    required this.ref,
    required this.header,
    this.refused,
  });

  final StrategyRef ref;
  final StrategyHeader header;
  final CommitRefusal? refused;
}

final class UnknownKindRow {
  const UnknownKindRow({required this.key, required this.text});

  final String key;
  final String text;
}

sealed class StrategyRead {
  int? get strategyLife;
}

sealed class StrategyWritten {
  const StrategyWritten();
}

final class WrittenNotRecorded extends StrategyWritten {
  const WrittenNotRecorded();
}

final class WrittenAt extends StrategyWritten {
  const WrittenAt(this.version);

  final int version;
}

final class WrittenUnreadable extends StrategyWritten {
  const WrittenUnreadable(this.stored);

  final String stored;
}

StrategyWritten writtenFrom(String stored) => switch (int.tryParse(stored)) {
  final version? when version >= 0 && '$version' == stored => WrittenAt(
    version,
  ),
  _ => WrittenUnreadable(stored),
};

final class StrategyContent implements StrategyRead {
  StrategyContent({
    required this.strategy,
    required Iterable<PageRow> pages,
    required Map<String, PageSettingsRow> settings,
    required Iterable<UnplacedRow> unplaced,
    required Iterable<ForeignName> foreignNames,
    this.sync = const LocalStrategy(),
    this.written = const WrittenNotRecorded(),
  }) : pages = List.unmodifiable(pages),
       settings = Map.unmodifiable(settings),
       unplaced = List.unmodifiable(unplaced),
       foreignNames = List.unmodifiable(foreignNames);

  final StrategyRow strategy;
  final List<PageRow> pages;
  final Map<String, PageSettingsRow> settings;
  final List<UnplacedRow> unplaced;
  final List<ForeignName> foreignNames;
  final StrategySync sync;
  final StrategyWritten written;

  @override
  int? get strategyLife => createdAtOf(strategy);
}

sealed class StrategySync {
  const StrategySync();
}

final class LocalStrategy extends StrategySync {
  const LocalStrategy();
}

final class CloudHeld extends StrategySync {
  CloudHeld(this.owner, List<UnreadableQueueRow> rows)
    : rows = List.unmodifiable(rows);

  final CloudOwner owner;
  final List<UnreadableQueueRow> rows;
}

final class HeldOnPage {
  HeldOnPage({
    required Map<String, ElementRow> elements,
    required Map<String, LineupGroupRow> lineupGroups,
  }) : elements = UnmodifiableMapView(elements),
       lineupGroups = UnmodifiableMapView(lineupGroups);

  static final nothing = HeldOnPage(elements: const {}, lineupGroups: const {});

  final Map<String, ElementRow> elements;
  final Map<String, LineupGroupRow> lineupGroups;
}

final class CloudStrategy extends StrategySync {
  CloudStrategy({
    required this.owner,
    required this.queue,
    required Map<String, EntryView> views,
    required this.tally,
  }) : views = Map.unmodifiable(views);

  final Account owner;
  final CloudQueue queue;
  final Map<String, EntryView> views;
  final Tally tally;
}

sealed class SettingsOnPage {
  const SettingsOnPage();
}

final class SettingsStored extends SettingsOnPage {
  const SettingsStored(this.row);

  final PageSettingsRow row;
}

final class NoSettingsStored extends SettingsOnPage {
  const NoSettingsStored();
}

sealed class PageContentState {
  const PageContentState();
}

final class ContentShown extends PageContentState {
  const ContentShown();
}

final class ContentNotRead extends PageContentState {
  const ContentNotRead();
}

final class PageContent implements StrategyRead {
  PageContent({
    required this.strategyLife,
    required this.page,
    required this.settings,
    required Iterable<ElementRow> elements,
    required Iterable<LineupGroupRow> lineupGroups,
    required Iterable<UnknownKindRow> unknownKinds,
    required Iterable<UnplacedRow> unplaced,
    required Iterable<ForeignName> foreignNames,
    this.sync = const LocalStrategy(),
    this.content = const ContentShown(),
  }) : elements = List.unmodifiable(elements),
       lineupGroups = List.unmodifiable(lineupGroups),
       unknownKinds = List.unmodifiable(unknownKinds),
       unplaced = List.unmodifiable(unplaced),
       foreignNames = List.unmodifiable(foreignNames);

  final PageRow page;
  final SettingsOnPage settings;
  final List<ElementRow> elements;
  final List<LineupGroupRow> lineupGroups;
  final List<UnknownKindRow> unknownKinds;
  final List<UnplacedRow> unplaced;
  final List<ForeignName> foreignNames;
  final StrategySync sync;
  final PageContentState content;
  @override
  final int? strategyLife;
}

sealed class LibraryState {
  const LibraryState();
}

final class LibraryOpen extends LibraryState {
  const LibraryOpen(this.list);

  final LibraryList list;
}

final class LibraryShut extends LibraryState {
  const LibraryShut(this.failure);

  final StorageFailure failure;
}

final class LibraryList {
  LibraryList({
    required List<StrategySummary> strategies,
    required List<UnreadableStrategyListing> unreadableStrategies,
    required List<FolderRow> folders,
    required List<UnplacedRow> unplaced,
  }) : strategies = List.unmodifiable(strategies),
       unreadableStrategies = List.unmodifiable(unreadableStrategies),
       folders = List.unmodifiable(folders),
       unplaced = List.unmodifiable(unplaced);

  final List<StrategySummary> strategies;
  final List<UnreadableStrategyListing> unreadableStrategies;
  final List<FolderRow> folders;
  final List<UnplacedRow> unplaced;
}

sealed class LibraryChange {
  const LibraryChange();
}

final class AddStrategy extends LibraryChange {
  const AddStrategy(this.rows, {this.writtenAt});

  final StrategyRowSet rows;
  final int? writtenAt;
}

final class RemoveStrategy extends LibraryChange {
  const RemoveStrategy(this.strategyPublicId);

  final String strategyPublicId;
}

final class RemoveUnreadableStrategy extends LibraryChange {
  const RemoveUnreadableStrategy(this.ref, {this.discarding});

  final StrategyRef ref;
  final DiscardsUnsentWork? discarding;
}

final class MoveStrategy extends LibraryChange {
  const MoveStrategy(this.strategyPublicId, this.folderPublicId);

  final String strategyPublicId;
  final String? folderPublicId;
}

final class PutFolder extends LibraryChange {
  const PutFolder(this.folder);

  final ReadableFolder folder;
}

final class RemoveFolder extends LibraryChange {
  const RemoveFolder(this.folderPublicId);

  final String folderPublicId;
}

sealed class StorageOrigin {
  const StorageOrigin();
}

final class StorageExisted extends StorageOrigin {
  const StorageExisted();
}

final class StorageCreated extends StorageOrigin {
  const StorageCreated();
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

final class StoreAlreadyOpen extends OpenProblem {
  const StoreAlreadyOpen();

  @override
  String toString() => 'StoreAlreadyOpen()';
}

final class EngineTooSmall extends OpenProblem {
  const EngineTooSmall(this.limit);

  final int limit;

  int get needed => longestName;

  @override
  String toString() => 'EngineTooSmall($limit < $needed)';
}

sealed class StrategySearch {
  const StrategySearch();
}

final class StrategiesFound extends StrategySearch {
  StrategiesFound({
    required List<StrategySummary> rebuilt,
    required List<UnreadableStrategyListing> unreadable,
  }) : rebuilt = List.unmodifiable(rebuilt),
       unreadable = List.unmodifiable(unreadable);

  final List<StrategySummary> rebuilt;
  final List<UnreadableStrategyListing> unreadable;
}

final class StrategiesNotSearched extends StrategySearch {
  const StrategiesNotSearched(this.failure);

  final StorageFailure failure;
}

sealed class ReportOutcome {
  const ReportOutcome();
}

final class ReportApplied extends ReportOutcome {
  ReportApplied(List<QueueEffect> effects)
    : effects = List.unmodifiable(effects);

  final List<QueueEffect> effects;
}

final class ReportNotApplicable extends ReportOutcome {
  ReportNotApplicable(this.why, {List<QueueEffect> effects = const []})
    : effects = List.unmodifiable(effects);

  final Inapplicable why;
  final List<QueueEffect> effects;
}

final class EditsGoThroughCommit extends ReportOutcome {
  const EditsGoThroughCommit();
}

final class Recorded {
  Recorded({required List<ReportOutcome> outcomes, required this.summary})
    : outcomes = List.unmodifiable(outcomes);

  final List<ReportOutcome> outcomes;
  final StrategySummary summary;
}

typedef RecordResult = Saving<Recorded, CommitRefusal>;
