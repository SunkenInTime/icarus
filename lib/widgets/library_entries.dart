import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/strategy_filter_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';

/// One folder in the library grid, tagged with the store it lives in so the
/// pill knows which provider path to use for moves, edits, and opening.
class LibraryFolderRow {
  const LibraryFolderRow({
    required this.folder,
    required this.store,
    required this.lastUpdated,
  });

  final Folder folder;
  final LibraryWorkspace store;

  /// Newest edit inside the folder tree, used for the "Date updated" sort.
  /// Cloud folders do not carry this yet and fall back to their creation date.
  final DateTime lastUpdated;

  String get id => folder.id;
}

/// One strategy in the library grid, from either store.
class LibraryStrategyRow {
  LibraryStrategyRow.local(StrategyData strategy, {required this.showDeviceBadge})
      : local = strategy,
        cloud = null;

  LibraryStrategyRow.cloud(CloudStrategyEntry entry)
      : cloud = entry,
        local = null,
        showDeviceBadge = false;

  final StrategyData? local;
  final CloudStrategyEntry? cloud;

  /// True for local strategies while the cloud is reachable, so the tile can
  /// say it is not synced.
  final bool showDeviceBadge;

  String get id => local?.id ?? cloud!.strategy.id;
  String get name => local?.name ?? cloud!.strategy.name;
  DateTime get createdAt => local?.createdAt ?? cloud!.strategy.createdAt;
  DateTime get lastEdited => local?.lastEdited ?? cloud!.strategy.lastEdited;
}

/// Combines both stores for the My Library root. A folder present in both
/// (a migrated one keeps its id) shows once, as its cloud copy.
List<LibraryFolderRow> mergeLibraryFolders({
  required List<LibraryFolderRow> local,
  required List<LibraryFolderRow> cloud,
}) {
  final cloudIds = {for (final row in cloud) row.id};
  return [
    ...cloud,
    for (final row in local)
      if (!cloudIds.contains(row.id)) row,
  ];
}

/// Same rule as [mergeLibraryFolders], for strategies.
List<LibraryStrategyRow> mergeLibraryStrategies({
  required List<LibraryStrategyRow> local,
  required List<LibraryStrategyRow> cloud,
}) {
  final cloudIds = {for (final row in cloud) row.id};
  return [
    ...cloud,
    for (final row in local)
      if (!cloudIds.contains(row.id)) row,
  ];
}

List<LibraryFolderRow> sortLibraryFolders(
  List<LibraryFolderRow> rows,
  StrategyFilterState filter,
) {
  final direction = filter.sortOrder == SortOrder.ascending ? 1 : -1;
  final sorted = [...rows];
  sorted.sort((a, b) {
    final result = switch (filter.sortBy) {
      SortBy.alphabetical =>
        a.folder.name.toLowerCase().compareTo(b.folder.name.toLowerCase()),
      SortBy.dateCreated => a.folder.dateCreated.compareTo(b.folder.dateCreated),
      SortBy.dateUpdated => a.lastUpdated.compareTo(b.lastUpdated),
    };
    if (result != 0) return direction * result;
    return a.id.compareTo(b.id);
  });
  return sorted;
}

List<LibraryStrategyRow> sortLibraryStrategies(
  List<LibraryStrategyRow> rows,
  StrategyFilterState filter,
) {
  final direction = filter.sortOrder == SortOrder.ascending ? 1 : -1;
  final sorted = [...rows];
  sorted.sort((a, b) {
    final result = switch (filter.sortBy) {
      SortBy.alphabetical =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      SortBy.dateCreated => a.createdAt.compareTo(b.createdAt),
      SortBy.dateUpdated => a.lastEdited.compareTo(b.lastEdited),
    };
    return direction * result;
  });
  return sorted;
}
