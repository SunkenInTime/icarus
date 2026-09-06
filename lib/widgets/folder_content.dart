import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_context_menu_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/pinned_items_provider.dart';
import 'package:icarus/providers/strategy_filter_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/widgets/custom_search_field.dart';
import 'package:icarus/providers/library_navigation_provider.dart';
import 'package:icarus/widgets/library_breadcrumb.dart';
import 'package:icarus/widgets/library_entries.dart';
import 'package:icarus/widgets/dialogs/auth/auth_dialog.dart';
import 'package:icarus/widgets/dialogs/share_links_dialog.dart';
import 'package:icarus/widgets/drop_insertion_indicator.dart';
import 'package:icarus/widgets/folder_pill.dart';
import 'package:icarus/widgets/hover_dot_grid.dart';
import 'package:icarus/widgets/ica_drop_target.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile.dart';
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
  const FolderContent({
    super.key,
    this.folder,
    required this.onCreateStrategy,
  });

  /// The open folder, or null at a tab's root.
  final Folder? folder;
  final VoidCallback onCreateStrategy;

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
    final tab = ref.watch(libraryTabProvider);
    switch (tab) {
      case LibraryTab.community:
        return _buildCommunityPlaceholder(context, ref);
      case LibraryTab.shared:
        return _crossFade(_buildCloudBody(context, ref));
      case LibraryTab.library:
        if (folder == null) {
          return _crossFade(_buildLibraryRoot(context, ref));
        }
        final store = ref.watch(libraryWorkspaceProvider);
        if (store == LibraryWorkspace.cloud) {
          return _crossFade(_buildCloudBody(context, ref));
        }
        return _buildLocalFolder(context, ref);
    }
  }

  /// Skeleton -> content (and error transitions) cross-fade instead of
  /// hard-snapping.
  Widget _crossFade(Widget child) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      child: child,
    );
  }

  /// Reads the local library and hands the visible rows to [builder]. Used
  /// both inside a local folder and for the local half of the My Library root.
  Widget _withLocalStore(
    BuildContext context,
    WidgetRef ref, {
    required Widget Function(
      List<LibraryFolderRow> folders,
      List<LibraryStrategyRow> strategies,
    ) builder,
  }) {
    final cloudAvailable = ref.watch(isCloudWorkspaceAvailableProvider);
    final strategiesBoxListenable = ref.watch(strategiesListenable);
    final foldersBoxListenable = ref.watch(foldersListenable);
    return ValueListenableBuilder<Box<StrategyData>>(
      valueListenable: strategiesBoxListenable,
      builder: (context, strategyBox, _) {
        return ValueListenableBuilder<Box<Folder>>(
          valueListenable: foldersBoxListenable,
          builder: (context, folderBox, _) {
            final allFolders = folderBox.values.toList();
            final allStrategies = strategyBox.values.toList();
            final existingFolderIds = allFolders.map((item) => item.id).toSet();
            final folders = [
              for (final item in allFolders)
                if (folderBelongsToVisibleParent(
                  folder: item,
                  currentFolderId: folder?.id,
                ))
                  LibraryFolderRow(
                    folder: item,
                    store: LibraryWorkspace.local,
                    lastUpdated: folderLastUpdated(
                      folder: item,
                      allFolders: allFolders,
                      allStrategies: allStrategies,
                    ),
                  ),
            ];
            final strategies = [
              for (final item in allStrategies)
                if (strategyBelongsToVisibleFolder(
                  strategy: item,
                  currentFolderId: folder?.id,
                  existingFolderIds: existingFolderIds,
                ))
                  LibraryStrategyRow.local(
                    item,
                    showDeviceBadge: cloudAvailable,
                  ),
            ];
            return builder(folders, strategies);
          },
        );
      },
    );
  }

  Widget _buildLocalFolder(BuildContext context, WidgetRef ref) {
    return _withLocalStore(
      context,
      ref,
      builder: (folders, strategies) => _buildScaffold(
        context,
        ref,
        folders: _filterFolders(ref, folders),
        strategies: _filterStrategies(ref, strategies),
        acceptsIcaDrops: true,
        emptyStateTitle: 'No strategies in this folder',
        emptyStateSubtitle:
            'Create a new strategy or drop strategies, folders, or .zip archives',
      ),
    );
  }

  /// My Library's root: everything on this computer and everything in the
  /// cloud, side by side. Inside a folder the view narrows to that folder's
  /// store.
  Widget _buildLibraryRoot(BuildContext context, WidgetRef ref) {
    final cloudAvailable = ref.watch(isCloudWorkspaceAvailableProvider);
    final foldersAsync = cloudAvailable ? ref.watch(cloudFoldersProvider) : null;
    final strategiesAsync =
        cloudAvailable ? ref.watch(cloudStrategiesProvider) : null;
    // Only the very first fetch shows the skeleton; dependency changes keep
    // the previous value.
    final isInitialLoading = foldersAsync != null &&
        strategiesAsync != null &&
        ((foldersAsync.isLoading && !foldersAsync.hasValue) ||
            (strategiesAsync.isLoading && !strategiesAsync.hasValue));
    if (isInitialLoading) {
      return const _LibraryLoadingSkeleton(key: ValueKey('cloud-loading'));
    }
    final cloudFailed =
        (foldersAsync?.hasError ?? false) || (strategiesAsync?.hasError ?? false);
    final cloudFolders = [
      for (final entry in foldersAsync?.valueOrNull ?? const <CloudFolderEntry>[])
        LibraryFolderRow(
          folder: entry.folder,
          store: LibraryWorkspace.cloud,
          lastUpdated: entry.folder.dateCreated,
        ),
    ];
    final cloudStrategies = [
      for (final entry
          in strategiesAsync?.valueOrNull ?? const <CloudStrategyEntry>[])
        LibraryStrategyRow.cloud(entry),
    ];

    return KeyedSubtree(
      key: const ValueKey('library-root'),
      child: _withLocalStore(
        context,
        ref,
        builder: (localFolders, localStrategies) => _buildScaffold(
          context,
          ref,
          folders: _filterFolders(
            ref,
            mergeLibraryFolders(local: localFolders, cloud: cloudFolders),
          ),
          strategies: _filterStrategies(
            ref,
            mergeLibraryStrategies(
              local: localStrategies,
              cloud: cloudStrategies,
            ),
          ),
          acceptsIcaDrops: true,
          banner: cloudFailed ? _CloudErrorBanner(onRetry: () => _retryCloud(ref)) : null,
          emptyStateKey: const ValueKey('library-empty-state'),
          emptyStateIcon: Icons.folder_outlined,
          emptyStateTitle: 'Your library is empty',
          emptyStateSubtitle: cloudAvailable
              ? 'Create your first strategy to keep it available across your '
                  'Icarus clients.'
              : 'Create a new strategy or drop strategies, folders, or .zip '
                  'archives here.',
          emptyStateAction: ShadButton(
            key: const ValueKey('library-empty-create-strategy'),
            onPressed: onCreateStrategy,
            leading: const Icon(Icons.add),
            child: const Text('Create Strategy'),
          ),
        ),
      ),
    );
  }

  void _retryCloud(WidgetRef ref) {
    ref.invalidate(cloudFolderTreeProvider);
    ref.invalidate(cloudStrategiesProvider);
  }

  /// A cloud folder, or the Shared tab.
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
    final isInitialLoading =
        (foldersAsync.isLoading && !foldersAsync.hasValue) ||
            (strategiesAsync.isLoading && !strategiesAsync.hasValue);
    if (isInitialLoading) {
      return const _LibraryLoadingSkeleton(
        key: ValueKey('cloud-loading'),
      );
    }
    final folders = [
      for (final entry in foldersAsync.valueOrNull ?? const <CloudFolderEntry>[])
        LibraryFolderRow(
          folder: entry.folder,
          store: LibraryWorkspace.cloud,
          lastUpdated: entry.folder.dateCreated,
        ),
    ];
    final strategies = [
      for (final entry
          in strategiesAsync.valueOrNull ?? const <CloudStrategyEntry>[])
        LibraryStrategyRow.cloud(entry),
    ];
    final isSharedWithMe = cloudSection == CloudLibrarySection.sharedWithMe;
    return KeyedSubtree(
      key: const ValueKey('cloud-content'),
      child: _buildScaffold(
        context,
        ref,
        folders: _filterFolders(ref, folders),
        strategies: _filterStrategies(ref, strategies),
        acceptsIcaDrops: false,
        emptyStateKey: isSharedWithMe && folder == null
            ? const ValueKey('shared-empty-state')
            : null,
        emptyStateIcon: isSharedWithMe && folder == null
            ? Icons.people_outline
            : null,
        emptyStateTitle: isSharedWithMe && folder == null
            ? 'Nothing shared with you yet'
            : 'No strategies in this folder',
        emptyStateSubtitle: isSharedWithMe && folder == null
            ? 'Add a share link or code from a teammate to keep it here.'
            : isSharedWithMe
                ? 'Strategies shared into this folder will show up here.'
                : 'Create a new strategy to fill it.',
        emptyStateAction: isSharedWithMe
            ? (folder == null
                ? ShadButton(
                    key: const ValueKey('shared-empty-add-item'),
                    onPressed: () => showAddSharedItemDialog(context),
                    leading: const Icon(LucideIcons.link),
                    child: const Text('Add by Link or Code'),
                  )
                : null)
            : ShadButton(
                key: const ValueKey('cloud-empty-create-strategy'),
                onPressed: onCreateStrategy,
                leading: const Icon(Icons.add),
                child: const Text('Create Strategy'),
              ),
      ),
    );
  }

  List<LibraryFolderRow> _filterFolders(
    WidgetRef ref,
    List<LibraryFolderRow> folders,
  ) {
    final search = ref.watch(strategySearchQueryProvider).trim().toLowerCase();
    final filter = ref.watch(strategyFilterProvider);
    final filtered = search.isEmpty
        ? folders
        : folders
            .where((row) => row.folder.name.toLowerCase().contains(search))
            .toList();
    final sorted = sortLibraryFolders(filtered, filter);
    final pinned = ref.watch(pinnedItemsProvider);
    return search.isEmpty && pinned.isNotEmpty
        ? sortPinnedItemsFirst(sorted, pinned, (row) => row.id)
        : sorted;
  }

  List<LibraryStrategyRow> _filterStrategies(
    WidgetRef ref,
    List<LibraryStrategyRow> strategies,
  ) {
    final search = ref.watch(strategySearchQueryProvider).trim().toLowerCase();
    final filter = ref.watch(strategyFilterProvider);
    final filtered = search.isEmpty
        ? strategies
        : strategies
            .where((row) => row.name.toLowerCase().contains(search))
            .toList();
    final sorted = sortLibraryStrategies(filtered, filter);
    final pinned = ref.watch(pinnedItemsProvider);
    return search.isEmpty && pinned.isNotEmpty
        ? sortPinnedItemsFirst(sorted, pinned, (row) => row.id)
        : sorted;
  }

  Widget _buildScaffold(
    BuildContext context,
    WidgetRef ref, {
    required List<LibraryFolderRow> folders,
    required List<LibraryStrategyRow> strategies,
    required bool acceptsIcaDrops,
    Widget? banner,
    Key? emptyStateKey,
    IconData? emptyStateIcon,
    required String emptyStateTitle,
    required String emptyStateSubtitle,
    Widget? emptyStateAction,
  }) {
    final hasStrategies = strategies.isNotEmpty;
    final Widget emptyState = Center(
      key: emptyStateKey,
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
            if (emptyStateAction != null) ...[
              const SizedBox(height: 18),
              emptyStateAction,
            ],
          ],
        ),
      ),
    );
    final Widget content = LayoutBuilder(
      builder: (context, constraints) {
        const double minTileWidth = 250;
        const double spacing = strategyTileGridSpacing;
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
                    children: [
                      for (final row in folders)
                        FolderPill(
                          key: ValueKey(row.id),
                          folder: row.folder,
                          store: row.store,
                        ),
                    ],
                  ),
                ),
              ),
            if (hasStrategies)
              SliverPadding(
                padding: const EdgeInsets.all(16 - strategyTileGutterOutset),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    mainAxisExtent: strategyTileGridMainAxisExtent,
                  ),
                  delegate: SliverChildListDelegate.fixed(
                    [
                      for (final row in strategies)
                        if (row.local case final local?)
                          StrategyTile.local(
                            key: ValueKey(row.id),
                            strategyData: local,
                            showDeviceBadge: row.showDeviceBadge,
                          )
                        else
                          _cloudTile(row.cloud!),
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
    final wrappedContent = acceptsIcaDrops
        ? IcaDropTarget(child: DropInsertionIndicatorScope(child: content))
        : DropInsertionIndicatorScope(child: content);
    final currentFolder = folder;

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => dismissLibraryContextMenus(ref),
      child: Stack(
        children: [
          const Positioned.fill(
            child: Padding(
              padding: EdgeInsets.all(4.0),
              child: HoverDotGrid(),
            ),
          ),
          Positioned.fill(
            child: Column(
              children: [
                if (currentFolder != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 16, 0),
                    child: LibraryBreadcrumb(folder: currentFolder),
                  ),
                if (banner != null) banner,
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeOutCubic,
                    child: (folders.isEmpty && !hasStrategies)
                        ? KeyedSubtree(
                            key: const ValueKey('library-empty'),
                            child: acceptsIcaDrops
                                ? IcaDropTarget(child: emptyState)
                                : emptyState,
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
      ),
    );
  }

  Widget _cloudTile(CloudStrategyEntry entry) {
    final caps = StrategyCapabilities.fromCloudRole(entry.role);
    return StrategyTile.cloud(
      key: ValueKey(entry.strategy.id),
      cloudStrategy: entry,
      canRename: caps.canRenameStrategy,
      canDuplicate: caps.canDuplicateStrategy,
      canDelete: caps.canDeleteStrategy,
      canMove: caps.canMoveStrategy,
    );
  }

  Widget _buildCloudUnavailableState(BuildContext context, WidgetRef ref) {
    return _LibraryMessageState(
      icon: Icons.cloud_off_outlined,
      iconColor: Settings.tacticalVioletTheme.mutedForeground,
      title: 'Cloud unavailable',
      subtitle: 'Sign in again to reach your online strategies, or go back '
          'to your library to keep working.',
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
          onPressed: ref.read(libraryNavigationProvider).showLibrary,
          child: const Text('Back to My Library'),
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
          onPressed: () => _retryCloud(ref),
          child: const Text('Retry'),
        ),
        ShadButton.secondary(
          onPressed: ref.read(libraryNavigationProvider).showLibrary,
          child: const Text('Back to My Library'),
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
          onPressed: ref.read(libraryNavigationProvider).showLibrary,
          child: const Text('Back to My Library'),
        ),
      ],
    );
  }
}

/// Shown above the My Library root when the cloud half failed to load. The
/// local half stays usable underneath.
class _CloudErrorBanner extends StatelessWidget {
  const _CloudErrorBanner({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        key: const ValueKey('cloud-error-banner'),
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        decoration: BoxDecoration(
          color: Settings.tacticalVioletTheme.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Settings.tacticalVioletTheme.border),
        ),
        child: Row(
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 16,
              color: Settings.tacticalVioletTheme.destructive,
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                "Couldn't load your cloud library. Showing what's on this "
                'computer.',
              ),
            ),
            ShadButton.ghost(
              height: 28,
              leading: const Icon(LucideIcons.refreshCw, size: 14),
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
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
            child: HoverDotGrid(),
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
            child: HoverDotGrid(),
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
