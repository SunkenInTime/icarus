import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/strategy_filter_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/widgets/custom_search_field.dart';
import 'package:icarus/widgets/dot_painter.dart';
import 'package:icarus/widgets/folder_pill.dart';
import 'package:icarus/widgets/ica_drop_target.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class FolderContent extends ConsumerWidget {
  FolderContent({super.key, this.folder});

  final Folder? folder;
  final TextEditingController searchController = TextEditingController();

  static final strategiesListenable =
      Provider<ValueListenable<Box<StrategyData>>>((ref) {
    return Hive.box<StrategyData>(HiveBoxNames.strategiesBox).listenable();
  });

  static final foldersListenable =
      Provider<ValueListenable<Box<Folder>>>((ref) {
    return Hive.box<Folder>(HiveBoxNames.foldersBox).listenable();
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspace = ref.watch(libraryWorkspaceProvider);
    if (workspace == LibraryWorkspace.community) {
      return _buildCommunityPlaceholder(context, ref);
    }

    final isCloud = workspace == LibraryWorkspace.cloud;
    if (isCloud) {
      final cloudSection = ref.watch(cloudLibrarySectionProvider);
      final cloudAvailable = ref.watch(isCloudWorkspaceAvailableProvider);
      if (!cloudAvailable) {
        return _buildCloudUnavailableState(context, ref);
      }
      final folders = (ref.watch(cloudFoldersProvider).valueOrNull ?? const [])
          .map(FolderProvider.cloudSummaryToFolder)
          .toList(growable: false);
      final strategies =
          ref.watch(cloudStrategiesProvider).valueOrNull ?? const [];
      return _buildScaffold(
        context,
        ref,
        folders: _filterFolders(ref, folders),
        localStrategies: const [],
        cloudStrategies: _filterCloudStrategies(ref, strategies),
        isCloud: true,
        emptyStateTitle: cloudSection == CloudLibrarySection.sharedWithMe
            ? 'No shared items yet'
            : 'No cloud strategies yet',
        emptyStateSubtitle: cloudSection == CloudLibrarySection.sharedWithMe
            ? 'Shared folders and strategies will appear here'
            : 'Create a cloud strategy to start your online workspace',
      );
    }

    final strategiesBoxListenable = ref.watch(strategiesListenable);
    final foldersBoxListenable = ref.watch(foldersListenable);
    return ValueListenableBuilder<Box<StrategyData>>(
      valueListenable: strategiesBoxListenable,
      builder: (context, strategyBox, _) {
        return ValueListenableBuilder<Box<Folder>>(
          valueListenable: foldersBoxListenable,
          builder: (context, folderBox, _) {
            final folders = folderBox.values
                .where((item) => item.parentID == folder?.id)
                .toList();
            final strategies = strategyBox.values
                .where((item) => item.folderID == folder?.id)
                .toList();
            return _buildScaffold(
              context,
              ref,
              folders: _filterFolders(ref, folders),
              localStrategies: _filterLocalStrategies(ref, strategies),
              cloudStrategies: const [],
              isCloud: false,
              emptyStateTitle: 'No strategies available',
              emptyStateSubtitle:
                  'Create a new strategy or drop strategies, folders, or .zip archives',
            );
          },
        );
      },
    );
  }

  List<Folder> _filterFolders(WidgetRef ref, List<Folder> folders) {
    final search = ref.watch(strategySearchQueryProvider).trim().toLowerCase();
    final filtered = [...folders];
    if (search.isNotEmpty) {
      filtered.retainWhere(
        (folder) => folder.name.toLowerCase().contains(search),
      );
    }
    filtered.sort((a, b) => a.dateCreated.compareTo(b.dateCreated));
    return filtered;
  }

  List<StrategyData> _filterLocalStrategies(
    WidgetRef ref,
    List<StrategyData> strategies,
  ) {
    final search = ref.watch(strategySearchQueryProvider).trim().toLowerCase();
    final filter = ref.watch(strategyFilterProvider);
    final filtered = [...strategies];
    if (search.isNotEmpty) {
      filtered.retainWhere(
        (strategy) => strategy.name.toLowerCase().contains(search),
      );
    }

    Comparator<StrategyData> comparator = switch (filter.sortBy) {
      SortBy.alphabetical => (a, b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      SortBy.dateCreated => (a, b) => a.createdAt.compareTo(b.createdAt),
      SortBy.dateUpdated => (a, b) => a.lastEdited.compareTo(b.lastEdited),
    };

    final direction = filter.sortOrder == SortOrder.ascending ? 1 : -1;
    filtered.sort((a, b) => direction * comparator(a, b));
    return filtered;
  }

  List<CloudStrategySummary> _filterCloudStrategies(
    WidgetRef ref,
    List<CloudStrategySummary> strategies,
  ) {
    final search = ref.watch(strategySearchQueryProvider).trim().toLowerCase();
    final filter = ref.watch(strategyFilterProvider);
    final filtered = [...strategies];
    if (search.isNotEmpty) {
      filtered.retainWhere(
        (strategy) => strategy.name.toLowerCase().contains(search),
      );
    }

    Comparator<CloudStrategySummary> comparator = switch (filter.sortBy) {
      SortBy.alphabetical => (a, b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      SortBy.dateCreated => (a, b) => a.createdAt.compareTo(b.createdAt),
      SortBy.dateUpdated => (a, b) => a.updatedAt.compareTo(b.updatedAt),
    };

    final direction = filter.sortOrder == SortOrder.ascending ? 1 : -1;
    filtered.sort((a, b) => direction * comparator(a, b));
    return filtered;
  }

  Widget _buildScaffold(
    BuildContext context,
    WidgetRef ref, {
    required List<Folder> folders,
    required List<StrategyData> localStrategies,
    required List<CloudStrategySummary> cloudStrategies,
    required bool isCloud,
    required String emptyStateTitle,
    required String emptyStateSubtitle,
  }) {
    final hasStrategies =
        localStrategies.isNotEmpty || cloudStrategies.isNotEmpty;
    final Widget emptyState = Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(emptyStateTitle),
          Text(emptyStateSubtitle),
        ],
      ),
    );
    final Widget content = LayoutBuilder(
      builder: (context, constraints) {
        const double minTileWidth = 250;
        const double spacing = 20;
        const double padding = 32;
        int crossAxisCount = ((constraints.maxWidth - padding + spacing) /
                (minTileWidth + spacing))
            .floor();
        crossAxisCount = crossAxisCount.clamp(1, double.infinity).toInt();

        return CustomScrollView(
          slivers: [
            if (folders.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: folders
                        .map((folder) => FolderPill(folder: folder))
                        .toList(),
                  ),
                ),
              ),
            if (hasStrategies)
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    mainAxisExtent: 250,
                    crossAxisSpacing: 20,
                    mainAxisSpacing: 20,
                  ),
                  delegate: SliverChildListDelegate.fixed(
                    [
                      ...localStrategies.map(
                        (strategy) => StrategyTile.local(
                          strategyData: strategy,
                        ),
                      ),
                      ...cloudStrategies.map((strategy) {
                        final caps =
                            StrategyCapabilities.fromCloudRole(strategy.role);
                        return StrategyTile.cloud(
                          cloudStrategy: strategy,
                          canRename: caps.canRenameStrategy,
                          canDuplicate: caps.canDuplicateStrategy,
                          canDelete: caps.canDeleteStrategy,
                          canMove: caps.canMoveStrategy,
                        );
                      }),
                    ],
                  ),
                ),
              )
            else if (folders.isNotEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.only(top: 48),
                    child: Text(
                      'No strategies in this folder',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
    final wrappedContent = isCloud ? content : IcaDropTarget(child: content);

    return Stack(
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
                        _SortSelect<SortBy>(
                          currentValue:
                              ref.watch(strategyFilterProvider).sortBy,
                          labels: StrategyFilterProvider.sortByLabels,
                          values: SortBy.values,
                          onChanged: (value) => ref
                              .read(strategyFilterProvider.notifier)
                              .setSortBy(value),
                        ),
                        _SortSelect<SortOrder>(
                          currentValue:
                              ref.watch(strategyFilterProvider).sortOrder,
                          labels: StrategyFilterProvider.sortOrderLabels,
                          values: SortOrder.values,
                          onChanged: (value) => ref
                              .read(strategyFilterProvider.notifier)
                              .setSortOrder(value),
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
                child: (folders.isEmpty && !hasStrategies)
                    ? (isCloud ? emptyState : IcaDropTarget(child: emptyState))
                    : wrappedContent,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCloudUnavailableState(BuildContext context, WidgetRef ref) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('Cloud workspace unavailable'),
          const SizedBox(height: 8),
          const Text(
            'Sign in again or switch back to Local to keep working.',
          ),
          const SizedBox(height: 16),
          ShadButton.secondary(
            onPressed: () {
              ref
                  .read(libraryWorkspaceProvider.notifier)
                  .select(LibraryWorkspace.local);
            },
            child: const Text('Back to Local'),
          ),
        ],
      ),
    );
  }

  Widget _buildCommunityPlaceholder(BuildContext context, WidgetRef ref) {
    return Stack(
      children: [
        const Positioned.fill(
          child: Padding(
            padding: EdgeInsets.all(4.0),
            child: DotGrid(),
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.public,
                  size: 38,
                  color: Settings.tacticalVioletTheme.primary,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Community strats are coming soon',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  'This space is reserved for public lineups, team executes, and discoverable strategy packs.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Settings.tacticalVioletTheme.mutedForeground,
                  ),
                ),
                const SizedBox(height: 18),
                ShadButton.secondary(
                  onPressed: () {
                    ref
                        .read(libraryWorkspaceProvider.notifier)
                        .select(LibraryWorkspace.local);
                  },
                  child: const Text('Back to Local'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SortSelect<T> extends StatelessWidget {
  const _SortSelect({
    required this.currentValue,
    required this.labels,
    required this.values,
    required this.onChanged,
  });

  final T currentValue;
  final Map<T, String> labels;
  final Iterable<T> values;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return ShadSelect<T>(
      decoration: ShadDecoration(
        color: Settings.tacticalVioletTheme.card,
        shadows: const [Settings.cardForegroundBackdrop],
      ),
      initialValue: currentValue,
      selectedOptionBuilder: (context, value) => Text(labels[value]!),
      options: [
        for (final value in values)
          ShadOption(
            value: value,
            child: Text(labels[value]!),
          ),
      ],
      onChanged: (value) {
        if (value != null) {
          onChanged(value);
        }
      },
    );
  }
}
