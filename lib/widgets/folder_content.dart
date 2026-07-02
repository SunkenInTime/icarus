import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_context_menu_provider.dart';
import 'package:icarus/providers/pinned_items_provider.dart';
import 'package:icarus/providers/strategy_filter_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile.dart';
import 'package:icarus/widgets/custom_search_field.dart';
import 'package:icarus/widgets/ica_drop_target.dart';
import 'package:icarus/widgets/dot_painter.dart';
import 'package:icarus/widgets/drop_insertion_indicator.dart';
import 'package:icarus/widgets/folder_card.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

@visibleForTesting
bool strategyBelongsToVisibleFolder({
  required StrategyData strategy,
  required String? currentFolderId,
  required Set<String> existingFolderIds,
}) {
  if (currentFolderId != null) {
    return strategy.folderID == currentFolderId;
  }

  final strategyFolderId = strategy.folderID;
  return strategyFolderId == null ||
      !existingFolderIds.contains(strategyFolderId);
}

@visibleForTesting
bool folderBelongsToVisibleParent({
  required Folder folder,
  required String? currentFolderId,
}) {
  return folder.parentID == currentFolderId;
}

@visibleForTesting
DateTime folderLastUpdated({
  required Folder folder,
  required Iterable<Folder> allFolders,
  required Iterable<StrategyData> allStrategies,
}) {
  var latest = folder.dateCreated;

  for (final strategy in strategiesInFolderTree(
    folder: folder,
    allFolders: allFolders,
    allStrategies: allStrategies,
  )) {
    if (strategy.lastEdited.isAfter(latest)) {
      latest = strategy.lastEdited;
    }
  }

  return latest;
}

@visibleForTesting
List<StrategyData> strategiesInFolderTree({
  required Folder folder,
  required Iterable<Folder> allFolders,
  required Iterable<StrategyData> allStrategies,
}) {
  final folderIds = _folderAndDescendantIds(folder, allFolders);
  return [
    for (final strategy in allStrategies)
      if (strategy.folderID != null && folderIds.contains(strategy.folderID))
        strategy,
  ];
}

@visibleForTesting
int compareFoldersForSort({
  required Folder a,
  required Folder b,
  required SortBy sortBy,
  required Iterable<Folder> allFolders,
  required Iterable<StrategyData> allStrategies,
}) {
  final result = switch (sortBy) {
    SortBy.alphabetical => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    SortBy.dateCreated => a.dateCreated.compareTo(b.dateCreated),
    SortBy.dateUpdated => folderLastUpdated(
        folder: a,
        allFolders: allFolders,
        allStrategies: allStrategies,
      ).compareTo(
        folderLastUpdated(
          folder: b,
          allFolders: allFolders,
          allStrategies: allStrategies,
        ),
      ),
  };

  if (result != 0) return result;
  return a.id.compareTo(b.id);
}

Set<String> _folderAndDescendantIds(Folder root, Iterable<Folder> allFolders) {
  final foldersByParent = <String, List<Folder>>{};
  for (final folder in allFolders) {
    final parentID = folder.parentID;
    if (parentID == null) continue;
    (foldersByParent[parentID] ??= []).add(folder);
  }

  final ids = <String>{};
  final pending = <Folder>[root];
  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    if (!ids.add(current.id)) continue;
    pending.addAll(foldersByParent[current.id] ?? const []);
  }

  return ids;
}

class FolderContent extends ConsumerWidget {
  FolderContent({super.key, this.folder});

  final Folder? folder; // null for root
  final strategiesListenable =
      Provider<ValueListenable<Box<StrategyData>>>((ref) {
    return Hive.box<StrategyData>(HiveBoxNames.strategiesBox).listenable();
  });

  final foldersListenable = Provider<ValueListenable<Box<Folder>>>((ref) {
    return Hive.box<Folder>(HiveBoxNames.foldersBox).listenable();
  });

  final TextEditingController searchController = TextEditingController();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Move all your existing grid logic here from FolderView
    // Filter by folder?.id instead of folder.id
    final strategiesBoxListenable = ref.watch(strategiesListenable);

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => dismissLibraryContextMenus(ref),
      child: Stack(
        children: [
          const Positioned.fill(
            child: Padding(
              padding: EdgeInsets.all(4.0),
              child: DotGrid(),
            ),
          ),
          Positioned.fill(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4.0, left: 16, right: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        spacing: 8,
                        children: [
                          ShadSelect<SortBy>(
                            decoration: ShadDecoration(
                              color: Settings.tacticalVioletTheme.card,
                              shadows: const [Settings.cardForegroundBackdrop],
                            ),
                            initialValue:
                                ref.watch(strategyFilterProvider).sortBy,
                            selectedOptionBuilder: (context, value) => Text(
                                StrategyFilterProvider.sortByLabels[value]!),
                            options: [
                              for (final sb in SortBy.values)
                                ShadOption(
                                  value: sb,
                                  child: Text(
                                      StrategyFilterProvider.sortByLabels[sb]!),
                                ),
                            ],
                            onChanged: (value) {
                              ref
                                  .read(strategyFilterProvider.notifier)
                                  .setSortBy(value!);
                            },
                          ),
                          ShadSelect<SortOrder>(
                            decoration: ShadDecoration(
                              color: Settings.tacticalVioletTheme.card,
                              shadows: const [Settings.cardForegroundBackdrop],
                            ),
                            initialValue:
                                ref.watch(strategyFilterProvider).sortOrder,
                            selectedOptionBuilder: (context, value) => Text(
                                StrategyFilterProvider.sortOrderLabels[value]!),
                            options: [
                              for (final so in SortOrder.values)
                                ShadOption(
                                  value: so,
                                  child: Text(StrategyFilterProvider
                                      .sortOrderLabels[so]!),
                                ),
                            ],
                            onChanged: (value) {
                              ref
                                  .read(strategyFilterProvider.notifier)
                                  .setSortOrder(value!);
                            },
                          ),
                        ],
                      ),
                      SizedBox(
                        height: 40,
                        child: SearchTextField(
                          controller: searchController,
                          collapsedWidth: 40,
                          expandedWidth: 250,
                          compact: true,
                          onChanged: (value) {},
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ValueListenableBuilder<Box<StrategyData>>(
                    valueListenable: strategiesBoxListenable,
                    builder: (context, strategyBox, _) {
                      final foldersBoxListenable = ref.watch(foldersListenable);
                      return ValueListenableBuilder<Box<Folder>>(
                        valueListenable: foldersBoxListenable,
                        builder: (context, folderBox, _) {
                          final allFolders = folderBox.values.toList();
                          final existingFolderIds =
                              allFolders.map((folder) => folder.id).toSet();
                          var folders = allFolders.toList();

                          final allStrategies = strategyBox.values.toList();
                          var strategies = allStrategies.toList();

                          final search = ref
                              .watch(strategySearchQueryProvider)
                              .trim()
                              .toLowerCase();
                          // Filter strategies and folders by the current folder
                          strategies.removeWhere(
                            (strategy) => !strategyBelongsToVisibleFolder(
                              strategy: strategy,
                              currentFolderId: folder?.id,
                              existingFolderIds: existingFolderIds,
                            ),
                          );
                          folders.removeWhere(
                            (listFolder) => !folderBelongsToVisibleParent(
                              folder: listFolder,
                              currentFolderId: folder?.id,
                            ),
                          );

                          if (search.isNotEmpty) {
                            strategies.retainWhere(
                              (strategy) =>
                                  strategy.name.toLowerCase().contains(search),
                            );
                            folders.retainWhere(
                              (listFolder) => listFolder.name
                                  .toLowerCase()
                                  .contains(search),
                            );
                          }
                          final filter = ref.watch(strategyFilterProvider);

                          // Pick the comparator once based on sortBy
                          Comparator<StrategyData> sortByComparator =
                              switch (filter.sortBy) {
                            SortBy.alphabetical => (a, b) => a.name
                                .toLowerCase()
                                .compareTo(b.name.toLowerCase()),
                            SortBy.dateCreated => (a, b) =>
                                a.createdAt.compareTo(b.createdAt),
                            SortBy.dateUpdated => (a, b) =>
                                a.lastEdited.compareTo(b.lastEdited),
                          };

                          final direction =
                              filter.sortOrder == SortOrder.ascending ? 1 : -1;

                          strategies.sort(
                            (a, b) => direction * sortByComparator(a, b),
                          );
                          folders.sort(
                            (a, b) =>
                                direction *
                                compareFoldersForSort(
                                  a: a,
                                  b: b,
                                  sortBy: filter.sortBy,
                                  allFolders: allFolders,
                                  allStrategies: allStrategies,
                                ),
                          );

                          final pinned = ref.watch(pinnedItemsProvider);
                          if (search.isEmpty && pinned.isNotEmpty) {
                            folders = sortPinnedItemsFirst(
                              folders,
                              pinned,
                              (folder) => folder.id,
                            );
                            strategies = sortPinnedItemsFirst(
                              strategies,
                              pinned,
                              (strategy) => strategy.id,
                            );
                          }

                          // Check if both folders and strategies are empty
                          if (folders.isEmpty && strategies.isEmpty) {
                            return const IcaDropTarget(
                              child: Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text('No strategies available'),
                                    Text(
                                        "Create a new strategy or drop strategies, folders, or .zip archives")
                                  ],
                                ),
                              ),
                            );
                          }

                          return IcaDropTarget(
                            child: DropInsertionIndicatorScope(
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  // Calculate how many columns can fit with minimum width
                                  const double minTileWidth =
                                      250; // Your minimum width
                                  const double spacing = 20;
                                  const double padding = 32; // 16 * 2

                                  int crossAxisCount = ((constraints.maxWidth -
                                              padding +
                                              spacing) /
                                          (minTileWidth + spacing))
                                      .floor();
                                  crossAxisCount = crossAxisCount
                                      .clamp(1, double.infinity)
                                      .toInt();

                                  return CustomScrollView(
                                    slivers: [
                                      // Folder cards section (wrap row)
                                      if (folders.isNotEmpty)
                                        SliverToBoxAdapter(
                                          child: Padding(
                                            // Horizontal padding is reduced by the
                                            // gutter baked into each FolderCard so
                                            // the cards still align at x=16.
                                            padding: const EdgeInsets.fromLTRB(
                                                16 - folderCardGutterOutset,
                                                16,
                                                16 - folderCardGutterOutset,
                                                8),
                                            child: Wrap(
                                              // Zero spacing: each card carries
                                              // half the 14px gutter as drop hit
                                              // area on both sides.
                                              spacing: 0,
                                              runSpacing: 14,
                                              children: folders
                                                  .map(
                                                    (f) => FolderCard(
                                                      key: ValueKey(f.id),
                                                      data: FolderCardViewData(
                                                        folder: f,
                                                        strategies:
                                                            strategiesInFolderTree(
                                                          folder: f,
                                                          allFolders:
                                                              allFolders,
                                                          allStrategies:
                                                              allStrategies,
                                                        ),
                                                        folderCount: allFolders
                                                            .where((folder) =>
                                                                folder
                                                                    .parentID ==
                                                                f.id)
                                                            .length,
                                                      ),
                                                    ),
                                                  )
                                                  .toList(),
                                            ),
                                          ),
                                        ),

                                      // Strategies grid
                                      if (strategies.isNotEmpty)
                                        SliverPadding(
                                          padding: const EdgeInsets.all(16),
                                          sliver: SliverGrid(
                                            gridDelegate:
                                                SliverGridDelegateWithFixedCrossAxisCount(
                                              crossAxisCount: crossAxisCount,
                                              mainAxisExtent: 250,
                                              crossAxisSpacing: 20,
                                              mainAxisSpacing: 20,
                                            ),
                                            delegate:
                                                SliverChildBuilderDelegate(
                                              (context, index) {
                                                return StrategyTile(
                                                  key: ValueKey(
                                                      strategies[index].id),
                                                  strategyData:
                                                      strategies[index],
                                                );
                                              },
                                              childCount: strategies.length,
                                            ),
                                          ),
                                        )
                                      else if (folders.isNotEmpty)
                                        // Show placeholder when only folders exist
                                        const SliverFillRemaining(
                                          hasScrollBody: false,
                                          child: Center(
                                            child: Padding(
                                              padding: EdgeInsets.only(top: 48),
                                              child: Text(
                                                'No strategies in this folder',
                                                style: TextStyle(
                                                  color: Colors.grey,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
