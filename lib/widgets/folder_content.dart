import 'dart:math' as math;

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
import 'package:icarus/widgets/dialogs/auth/auth_dialog.dart';
import 'package:icarus/widgets/dialogs/share_links_dialog.dart';
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
      // Wrapped in a switcher so skeleton -> content (and error transitions)
      // cross-fade instead of hard-snapping.
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeOutCubic,
        child: _buildCloudBody(context, ref),
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

  Widget _buildCloudBody(BuildContext context, WidgetRef ref) {
    final cloudSection = ref.watch(cloudLibrarySectionProvider);
    final cloudAvailable = ref.watch(isCloudWorkspaceAvailableProvider);
    if (!cloudAvailable) {
      return KeyedSubtree(
        key: const ValueKey('cloud-unavailable'),
        child: _buildCloudUnavailableState(context, ref),
      );
    }
    final foldersAsync = ref.watch(cloudFoldersProvider);
    final strategiesAsync = ref.watch(cloudStrategiesProvider);
    if (foldersAsync.hasError || strategiesAsync.hasError) {
      return KeyedSubtree(
        key: const ValueKey('cloud-error'),
        child: _buildCloudErrorState(context, ref),
      );
    }
    // Only the very first fetch shows the skeleton; dependency changes keep
    // the previous value, so navigating folders doesn't flash it.
    final isInitialLoading =
        (foldersAsync.isLoading && !foldersAsync.hasValue) ||
            (strategiesAsync.isLoading && !strategiesAsync.hasValue);
    if (isInitialLoading) {
      return const _LibraryLoadingSkeleton(
        key: ValueKey('cloud-loading'),
      );
    }
    final folders = (foldersAsync.valueOrNull ?? const [])
        .map(FolderProvider.cloudSummaryToFolder)
        .toList(growable: false);
    final strategies = strategiesAsync.valueOrNull ?? const [];
    final isSharedWithMe = cloudSection == CloudLibrarySection.sharedWithMe;
    return KeyedSubtree(
      key: const ValueKey('cloud-content'),
      child: _buildScaffold(
        context,
        ref,
        folders: _filterFolders(ref, folders),
        localStrategies: const [],
        cloudStrategies: _filterCloudStrategies(ref, strategies),
        isCloud: true,
        showAddSharedItemAction: isSharedWithMe,
        emptyStateIcon:
            isSharedWithMe ? Icons.people_outline : Icons.cloud_outlined,
        emptyStateTitle:
            isSharedWithMe ? 'No shared items yet' : 'No cloud strategies yet',
        emptyStateSubtitle: isSharedWithMe
            ? 'Shared folders and strategies will appear here'
            : 'Create a cloud strategy to start your online workspace',
      ),
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
    bool showAddSharedItemAction = false,
    IconData? emptyStateIcon,
    required String emptyStateTitle,
    required String emptyStateSubtitle,
  }) {
    final hasStrategies =
        localStrategies.isNotEmpty || cloudStrategies.isNotEmpty;
    final Widget emptyState = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (emptyStateIcon != null) ...[
              Icon(
                emptyStateIcon,
                size: 38,
                color: Settings.tacticalVioletTheme.mutedForeground,
              ),
              const SizedBox(height: 16),
            ],
            Text(
              emptyStateTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              emptyStateSubtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Settings.tacticalVioletTheme.mutedForeground,
              ),
            ),
            if (showAddSharedItemAction) ...[
              const SizedBox(height: 18),
              ShadButton(
                onPressed: () => showAddSharedItemDialog(context),
                leading: const Icon(LucideIcons.link),
                child: const Text('Add by Link or Code'),
              ),
            ],
          ],
        ),
      ),
    );
    final Widget content = LayoutBuilder(
      builder: (context, constraints) {
        const double minTileWidth = 250;
        const double spacing = 20;
        const double padding = 32;
        final crossAxisCount = math.max(
          1,
          ((constraints.maxWidth - padding + spacing) /
                  (minTileWidth + spacing))
              .floor(),
        );

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
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 48),
                    child: Text(
                      'No strategies in this folder',
                      style: TextStyle(
                        color: Settings.tacticalVioletTheme.mutedForeground,
                      ),
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
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeOutCubic,
                  child: (folders.isEmpty && !hasStrategies)
                      ? KeyedSubtree(
                          key: const ValueKey('library-empty'),
                          child: isCloud
                              ? emptyState
                              : IcaDropTarget(child: emptyState),
                        )
                      : KeyedSubtree(
                          key: const ValueKey('library-content'),
                          child: wrappedContent,
                        ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCloudUnavailableState(BuildContext context, WidgetRef ref) {
    return _LibraryMessageState(
      icon: Icons.cloud_off_outlined,
      iconColor: Settings.tacticalVioletTheme.mutedForeground,
      title: 'Cloud workspace unavailable',
      subtitle: 'Sign in again to reach your online strategies, or switch '
          'back to Local to keep working.',
      actions: [
        ShadButton(
          onPressed: () {
            showDialog<void>(
              context: context,
              builder: (_) => const AuthDialog(),
            );
          },
          child: const Text('Log In'),
        ),
        ShadButton.secondary(
          onPressed: () {
            ref
                .read(libraryWorkspaceProvider.notifier)
                .select(LibraryWorkspace.local);
          },
          child: const Text('Back to Local'),
        ),
      ],
    );
  }

  Widget _buildCloudErrorState(BuildContext context, WidgetRef ref) {
    return _LibraryMessageState(
      icon: Icons.cloud_off_outlined,
      iconColor: Settings.tacticalVioletTheme.destructive,
      title: "Couldn't load your cloud library",
      subtitle: 'Check your connection and try again.',
      actions: [
        ShadButton(
          leading: const Icon(LucideIcons.refreshCw, size: 14),
          onPressed: () {
            ref.invalidate(cloudFoldersProvider);
            ref.invalidate(cloudStrategiesProvider);
          },
          child: const Text('Retry'),
        ),
        ShadButton.secondary(
          onPressed: () {
            ref
                .read(libraryWorkspaceProvider.notifier)
                .select(LibraryWorkspace.local);
          },
          child: const Text('Back to Local'),
        ),
      ],
    );
  }

  Widget _buildCommunityPlaceholder(BuildContext context, WidgetRef ref) {
    return _LibraryMessageState(
      icon: Icons.public,
      iconColor: Settings.tacticalVioletTheme.primary,
      title: 'Community strats are coming soon',
      subtitle:
          'This space is reserved for public lineups, team executes, and discoverable strategy packs.',
      actions: [
        ShadButton.secondary(
          onPressed: () {
            ref
                .read(libraryWorkspaceProvider.notifier)
                .select(LibraryWorkspace.local);
          },
          child: const Text('Back to Local'),
        ),
      ],
    );
  }
}

/// Shared full-pane message layout (dot-grid backdrop, icon, title, subtitle,
/// action row) used by the community placeholder and cloud
/// unavailable/error states so they carry the same visual weight.
class _LibraryMessageState extends StatelessWidget {
  const _LibraryMessageState({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.actions,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
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
                Icon(icon, size: 38, color: iconColor),
                const SizedBox(height: 16),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Settings.tacticalVioletTheme.mutedForeground,
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < actions.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      actions[i],
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Pulsing placeholder shown while the cloud library streams its first
/// snapshot — previously the grid rendered the empty state during fetch.
class _LibraryLoadingSkeleton extends StatefulWidget {
  const _LibraryLoadingSkeleton({super.key});

  @override
  State<_LibraryLoadingSkeleton> createState() =>
      _LibraryLoadingSkeletonState();
}

class _LibraryLoadingSkeletonState extends State<_LibraryLoadingSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _controller.stop();
      _controller.value = 1;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final placeholderColor =
        Settings.tacticalVioletTheme.muted.withValues(alpha: 0.35);
    return Stack(
      children: [
        const Positioned.fill(
          child: Padding(
            padding: EdgeInsets.all(4.0),
            child: DotGrid(),
          ),
        ),
        Positioned.fill(
          child: FadeTransition(
            opacity: Tween<double>(begin: 0.45, end: 0.9).animate(
              CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                const double minTileWidth = 250;
                const double spacing = 20;
                const double padding = 32;
                final crossAxisCount = math.max(
                  1,
                  ((constraints.maxWidth - padding + spacing) /
                          (minTileWidth + spacing))
                      .floor(),
                );
                final tileCount = crossAxisCount * 2;

                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          for (var i = 0; i < 3; i++)
                            Container(
                              width: 128,
                              height: 44,
                              decoration: BoxDecoration(
                                color: placeholderColor,
                                borderRadius: BorderRadius.circular(22),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Expanded(
                        child: GridView.builder(
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: crossAxisCount,
                            mainAxisExtent: 250,
                            crossAxisSpacing: 20,
                            mainAxisSpacing: 20,
                          ),
                          itemCount: tileCount,
                          itemBuilder: (context, index) => DecoratedBox(
                            decoration: BoxDecoration(
                              color: placeholderColor,
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
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
