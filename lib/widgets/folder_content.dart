import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/client_upgrade_required_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_context_menu_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/services/cloud_needs_connection.dart';
import 'package:icarus/providers/pinned_items_provider.dart';
import 'package:icarus/providers/strategy_filter_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/widgets/client_upgrade_button.dart';
import 'package:icarus/widgets/custom_search_field.dart';
import 'package:icarus/providers/library_navigation_provider.dart';
import 'package:icarus/widgets/library_breadcrumb.dart';
import 'package:icarus/widgets/library_entries.dart';
import 'package:icarus/widgets/dialogs/auth/auth_dialog.dart';
import 'package:icarus/widgets/dialogs/share_links_dialog.dart';
import 'package:icarus/widgets/drop_insertion_indicator.dart';
import 'package:icarus/widgets/folder_card.dart';
import 'package:icarus/widgets/hover_dot_grid.dart';
import 'package:icarus/widgets/ica_drop_target.dart';
import 'package:icarus/widgets/replay/replay_library_content.dart';
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

/// The local library's folder tree, indexed once per build so each folder
/// card reads its own subtree instead of rescanning the whole library.
@visibleForTesting
class LocalFolderIndex {
  LocalFolderIndex({
    required Iterable<Folder> folders,
    required Iterable<StrategyData> strategies,
  }) {
    for (final folder in folders) {
      final parentID = folder.parentID;
      if (parentID == null) continue;
      (_foldersByParent[parentID] ??= []).add(folder);
    }
    var order = 0;
    for (final strategy in strategies) {
      _libraryOrder[strategy] = order++;
      final folderID = strategy.folderID;
      if (folderID == null) continue;
      (_strategiesByFolder[folderID] ??= []).add(strategy);
    }
  }

  final _foldersByParent = <String, List<Folder>>{};
  final _strategiesByFolder = <String, List<StrategyData>>{};
  final _libraryOrder = Map<StrategyData, int>.identity();

  int childFolderCount(String folderId) =>
      _foldersByParent[folderId]?.length ?? 0;

  /// Strategies in [root] and every folder below it, in library order.
  List<StrategyData> strategiesInTree(Folder root) {
    final visited = <String>{};
    final strategies = <StrategyData>[];
    final pending = <Folder>[root];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (!visited.add(current.id)) continue;
      strategies.addAll(_strategiesByFolder[current.id] ?? const []);
      pending.addAll(_foldersByParent[current.id] ?? const []);
    }
    return strategies
      ..sort((a, b) => _libraryOrder[a]!.compareTo(_libraryOrder[b]!));
  }
}

/// The newest edit among [strategies], or the folder's creation date when
/// none is newer.
@visibleForTesting
DateTime folderLastUpdated(Folder folder, List<StrategyData> strategies) {
  var latest = folder.dateCreated;
  for (final strategy in strategies) {
    if (strategy.lastEdited.isAfter(latest)) {
      latest = strategy.lastEdited;
    }
  }
  return latest;
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
      case LibraryTab.replays:
        return const ReplayLibraryContent();
      case LibraryTab.shared:
        return _crossFade(_buildCloudBody(context, ref));
      case LibraryTab.library:
        if (ref.watch(librarySignInRequiredProvider)) {
          return _crossFade(_buildSignInState(context, ref));
        }
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
    // Hidden, not deleted: the on-device library stays in storage for the
    // day this platform offers it again.
    if (!ref.watch(platformPolicyProvider).allowsLocalLibrary) {
      return builder(const [], const []);
    }
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
            final index = LocalFolderIndex(
              folders: allFolders,
              strategies: allStrategies,
            );
            final folders = [
              for (final item in allFolders)
                if (folderBelongsToVisibleParent(
                  folder: item,
                  currentFolderId: folder?.id,
                ))
                  _localFolderRow(item, index),
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
        acceptsIcaDrops: _acceptsIcaDrops(ref),
        emptyStateTitle: 'No strategies in this folder',
        emptyStateSubtitle:
            'Create a new strategy or drop strategies, folders, or .zip archives',
        emptyStateAction: ShadButton(
          key: const ValueKey('folder-empty-create-strategy'),
          onPressed: onCreateStrategy,
          leading: const Icon(LucideIcons.plus),
          child: const Text('Create Strategy'),
        ),
      ),
    );
  }

  /// My Library's root: everything on this computer and everything in the
  /// cloud, side by side. Inside a folder the view narrows to that folder's
  /// store.
  Widget _buildLibraryRoot(BuildContext context, WidgetRef ref) {
    final cloudAvailable = ref.watch(isCloudWorkspaceAvailableProvider);
    // Still connecting, or out of reach: the cloud half is this computer's
    // copy of it, if it kept one.
    final showsCopy = ref.watch(cloudLibraryShowsCopyProvider);
    final foldersAsync =
        cloudAvailable || showsCopy ? ref.watch(cloudFoldersProvider) : null;
    final strategiesAsync =
        cloudAvailable || showsCopy ? ref.watch(cloudStrategiesProvider) : null;
    final cloudFailed = (foldersAsync?.hasError ?? false) ||
        (strategiesAsync?.hasError ?? false);
    final bool cloudLoading;
    var cloudUnreachable = false;
    var connectingOverCopy = false;
    DateTime? offlineCopyMatchedAt;
    if (showsCopy) {
      final copyMatchedAt = ref.watch(cloudLibraryCopyMatchedAtProvider);
      final offline = ref.watch(cloudOfflineProvider);
      // Connecting with no copy waits as it always has; offline with no
      // copy offers the retry.
      cloudLoading = !offline && copyMatchedAt == null;
      cloudUnreachable = offline && copyMatchedAt == null;
      connectingOverCopy = !offline && copyMatchedAt != null;
      if (offline) offlineCopyMatchedAt = copyMatchedAt;
    } else if (foldersAsync == null || strategiesAsync == null) {
      // Signed in, and the session is still connecting to the cloud, or
      // gave up connecting.
      final signedIn = ref.watch(authProvider).isAuthenticated;
      final outcome = ref.watch(cloudWorkspaceOutcomeProvider);
      cloudLoading = signedIn && outcome == null;
      cloudUnreachable = signedIn && outcome == false;
    } else {
      // Only the very first fetch counts; dependency changes keep the
      // previous value.
      cloudLoading = !cloudFailed &&
          ((foldersAsync.isLoading && !foldersAsync.hasValue) ||
              (strategiesAsync.isLoading && !strategiesAsync.hasValue));
    }
    // With no local half to fall back on, a failed cloud is the whole page.
    if (cloudFailed && !ref.watch(platformPolicyProvider).allowsLocalLibrary) {
      return KeyedSubtree(
        key: const ValueKey('cloud-error'),
        child: _buildCloudErrorState(context, ref, offerLibrary: false),
      );
    }
    // The cloud half lands all at once, so the grid shifts once.
    final cloudFolders = _cloudFolderRows(
      ref,
      cloudLoading
          ? const <CloudFolderEntry>[]
          : foldersAsync?.valueOrNull ?? const <CloudFolderEntry>[],
    );
    final cloudStrategies = [
      if (!cloudLoading)
        for (final entry
            in strategiesAsync?.valueOrNull ?? const <CloudStrategyEntry>[])
          LibraryStrategyRow.cloud(entry),
    ];

    return KeyedSubtree(
      key: const ValueKey('library-root'),
      child: _withLocalStore(
        context,
        ref,
        builder: (localFolders, localStrategies) {
          final folders = _filterFolders(
            ref,
            mergeLibraryFolders(local: localFolders, cloud: cloudFolders),
          );
          final strategies = _filterStrategies(
            ref,
            mergeLibraryStrategies(
              local: localStrategies,
              cloud: cloudStrategies,
            ),
          );
          // What's on this computer shows while the cloud loads. With
          // nothing to show yet, the page waits for the cloud rather than
          // call the library empty.
          if (cloudLoading && folders.isEmpty && strategies.isEmpty) {
            return _crossFade(
              const _LibraryLoadingSkeleton(key: ValueKey('cloud-loading')),
            );
          }
          return _crossFade(
            KeyedSubtree(
              key: const ValueKey('library-root-content'),
              child: _buildScaffold(
                context,
                ref,
                folders: folders,
                strategies: strategies,
                acceptsIcaDrops: _acceptsIcaDrops(ref),
                banner: cloudFailed
                    ? _CloudErrorBanner(onRetry: () => _retryCloud(ref))
                    : offlineCopyMatchedAt != null
                        ? _CloudOfflineBanner(matchedAt: offlineCopyMatchedAt)
                        : cloudUnreachable
                            ? const _CloudUnreachableBanner()
                            : cloudLoading || connectingOverCopy
                                ? const _CloudLoadingBanner()
                                : null,
                emptyStateKey: const ValueKey('library-empty-state'),
                emptyStateIcon: LucideIcons.folder,
                emptyStateTitle: 'Your library is empty',
                emptyStateSubtitle: cloudAvailable
                    ? 'Create your first strategy to keep it available '
                        'across your Icarus clients.'
                    : 'Create a new strategy or drop strategies, folders, '
                        'or .zip archives here.',
                emptyStateAction: ShadButton(
                  key: const ValueKey('library-empty-create-strategy'),
                  onPressed: onCreateStrategy,
                  leading: const Icon(LucideIcons.plus),
                  child: const Text('Create Strategy'),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Dropped .ica files and backups import into the local library.
  bool _acceptsIcaDrops(WidgetRef ref) {
    final policy = ref.watch(platformPolicyProvider);
    return policy.allowsLocalLibrary &&
        policy.supports(PlatformFeature.importFiles);
  }

  LibraryFolderRow _localFolderRow(Folder folder, LocalFolderIndex index) {
    final strategies = index.strategiesInTree(folder);
    return LibraryFolderRow(
      folder: folder,
      store: LibraryWorkspace.local,
      lastUpdated: folderLastUpdated(folder, strategies),
      card: FolderCardViewData(
        folder: folder,
        strategies: strategies,
        folderCount: index.childFolderCount(folder.id),
      ),
    );
  }

  List<LibraryFolderRow> _cloudFolderRows(
    WidgetRef ref,
    List<CloudFolderEntry> entries,
  ) {
    if (entries.isEmpty) return const [];
    // Child counts come from the whole tree, counted once rather than once
    // per card.
    final tree = ref.watch(cloudAllFoldersProvider).valueOrNull ?? const [];
    final childFolderCounts = <String, int>{};
    for (final item in tree) {
      final parentID = item.folder.parentID;
      if (parentID == null) continue;
      childFolderCounts[parentID] = (childFolderCounts[parentID] ?? 0) + 1;
    }
    return [
      for (final entry in entries) _cloudFolderRow(entry, childFolderCounts),
    ];
  }

  LibraryFolderRow _cloudFolderRow(
    CloudFolderEntry entry,
    Map<String, int> childFolderCounts,
  ) {
    return LibraryFolderRow(
      folder: entry.folder,
      store: LibraryWorkspace.cloud,
      lastUpdated: entry.folder.dateCreated,
      cloudRole: entry.role,
      card: FolderCardViewData.summary(
        folder: entry.folder,
        folderCount: childFolderCounts[entry.folder.id] ?? 0,
        strategyCount: entry.strategyCount,
        maps: entry.mapPeeks,
        agentTypes: entry.agentTypes,
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
    if (!ref.watch(isCloudLibraryBrowsableProvider)) {
      return KeyedSubtree(
        key: const ValueKey('cloud-unavailable'),
        child: _buildCloudUnavailableState(context, ref),
      );
    }
    Widget? banner;
    if (ref.watch(cloudLibraryShowsCopyProvider)) {
      // Still connecting, or out of reach: this computer's copy, if it kept
      // this folder.
      final copyMatchedAt = ref.watch(cloudLibraryCopyMatchedAtProvider);
      final offline = ref.watch(cloudOfflineProvider);
      if (copyMatchedAt == null) {
        return offline
            ? KeyedSubtree(
                key: const ValueKey('cloud-not-kept'),
                child: _buildNotKeptState(context, ref),
              )
            : const _LibraryLoadingSkeleton(key: ValueKey('cloud-loading'));
      }
      banner = offline
          ? _CloudOfflineBanner(matchedAt: copyMatchedAt)
          : const _CloudLoadingBanner();
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
    final folders = _cloudFolderRows(
      ref,
      foldersAsync.valueOrNull ?? const <CloudFolderEntry>[],
    );
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
        banner: banner,
        emptyStateKey: isSharedWithMe && folder == null
            ? const ValueKey('shared-empty-state')
            : null,
        emptyStateIcon:
            isSharedWithMe && folder == null ? LucideIcons.users : null,
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
                    onPressed: () {
                      if (refuseCloudChangeWhileOffline(
                        ref.read(cloudLibraryShowsCopyProvider),
                      )) {
                        return;
                      }
                      showAddSharedItemDialog(context);
                    },
                    leading: const Icon(LucideIcons.link),
                    child: const Text('Add by Link or Code'),
                  )
                : null)
            : ShadButton(
                key: const ValueKey('cloud-empty-create-strategy'),
                onPressed: onCreateStrategy,
                leading: const Icon(LucideIcons.plus),
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
    // A search that filtered everything out is not an empty library: say so,
    // and offer nothing to create.
    final searching = ref.watch(strategySearchQueryProvider).trim().isNotEmpty;
    final icon = searching ? null : emptyStateIcon;
    final title = searching ? 'No matches' : emptyStateTitle;
    final subtitle = searching ? 'Try a different search' : emptyStateSubtitle;
    final action = searching ? null : emptyStateAction;
    final Widget emptyState = Center(
      key: emptyStateKey,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 38,
                color: Settings.tacticalVioletTheme.mutedForeground,
              ),
              const SizedBox(height: 16),
            ],
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Settings.tacticalVioletTheme.mutedForeground,
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: 18),
              action,
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
            // Folder cards, on the same columns as the strategies below.
            if (folders.isNotEmpty)
              SliverPadding(
                // Each card carries half the gutter as drop hit area, so
                // the row's padding shrinks by that much to keep x=16.
                padding: const EdgeInsets.fromLTRB(
                  16 - folderCardGutterOutset,
                  16,
                  16 - folderCardGutterOutset,
                  8,
                ),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    mainAxisExtent: folderCardHeight,
                    mainAxisSpacing: 14,
                  ),
                  delegate: SliverChildListDelegate.fixed(
                    [
                      for (final row in folders)
                        FolderCard(
                          key: ValueKey(row.id),
                          data: row.card,
                          store: row.store,
                          cloudRole: row.cloudRole,
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
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
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
    // A live session that cannot reach the cloud retries; only a signed-out
    // user is asked to log in.
    final signedIn = ref.watch(authProvider).isAuthenticated;
    return _LibraryMessageState(
      icon: LucideIcons.cloudOff,
      iconColor: Settings.tacticalVioletTheme.mutedForeground,
      title: 'Cloud unavailable',
      subtitle: signedIn
          ? 'Retry to reach your online strategies, or go back to your '
              'library to keep working.'
          : 'Sign in again to reach your online strategies, or go back '
              'to your library to keep working.',
      actions: [
        if (signedIn)
          ShadButton(
            leading: const Icon(LucideIcons.refreshCw, size: 14),
            onPressed: () => ref
                .read(authProvider.notifier)
                .reinitializeConvexAuth(source: 'cloud_unavailable_retry'),
            child: const Text('Retry'),
          )
        else
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

  /// [offerLibrary] is false when this state already fills My Library, so
  /// "Back to My Library" would go nowhere.
  Widget _buildCloudErrorState(
    BuildContext context,
    WidgetRef ref, {
    bool offerLibrary = true,
  }) {
    return _LibraryMessageState(
      icon: LucideIcons.cloudOff,
      iconColor: Settings.tacticalVioletTheme.destructive,
      title: "Couldn't load your cloud library",
      subtitle: 'Check your connection and try again.',
      actions: [
        ShadButton(
          leading: const Icon(LucideIcons.refreshCw, size: 14),
          onPressed: () => _retryCloud(ref),
          child: const Text('Retry'),
        ),
        if (offerLibrary)
          ShadButton.secondary(
            onPressed: ref.read(libraryNavigationProvider).showLibrary,
            child: const Text('Back to My Library'),
          ),
      ],
    );
  }

  /// A cloud folder, or Shared, opened while the cloud is out of reach on a
  /// computer that never kept a copy of it.
  Widget _buildNotKeptState(BuildContext context, WidgetRef ref) {
    final isShared = ref.watch(cloudLibrarySectionProvider) ==
        CloudLibrarySection.sharedWithMe;
    return _LibraryMessageState(
      icon: LucideIcons.cloudOff,
      iconColor: Settings.tacticalVioletTheme.mutedForeground,
      title: isShared && folder == null
          ? "Shared isn't on this computer yet"
          : "This folder isn't on this computer yet",
      subtitle: 'Icarus keeps what you open while online. This loads when '
          "you're back online.",
      actions: [
        ShadButton.secondary(
          onPressed: ref.read(libraryNavigationProvider).showLibrary,
          child: const Text('Back to My Library'),
        ),
      ],
    );
  }

  /// My Library on a platform that needs the cloud, before the cloud is
  /// reachable. Restoring a session holds the skeleton so the login prompt
  /// never flashes at a returning user; a session that cannot reach the
  /// cloud gets a retry, never a second login over the one it has.
  Widget _buildSignInState(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final restoring =
        auth.isLoading || auth.convexAuthStatus == ConvexAuthStatus.configuring;
    if (restoring) {
      return const _LibraryLoadingSkeleton(key: ValueKey('cloud-loading'));
    }
    if (auth.isAuthenticated) {
      // The server refuses this build: a retry is refused like the first
      // try, and only a reload or an update helps.
      if (ref.watch(clientUpgradeRequiredProvider)) {
        return KeyedSubtree(
          key: const ValueKey('library-cloud-unreachable'),
          child: ClientUpgradeNotice(
            builder: (context, message, action) => _LibraryMessageState(
              icon: LucideIcons.cloudOff,
              iconColor: Settings.tacticalVioletTheme.destructive,
              title: 'Your cloud library needs a newer Icarus',
              subtitle: message,
              actions: [if (action != null) action],
            ),
          ),
        );
      }
      return KeyedSubtree(
        key: const ValueKey('library-cloud-unreachable'),
        child: _LibraryMessageState(
          icon: LucideIcons.cloudOff,
          iconColor: Settings.tacticalVioletTheme.destructive,
          title: "Couldn't reach your cloud library",
          subtitle: auth.errorMessage ?? 'Check your connection and try again.',
          actions: [
            ShadButton(
              key: const ValueKey('library-cloud-retry'),
              leading: const Icon(LucideIcons.refreshCw, size: 14),
              onPressed: () => ref
                  .read(authProvider.notifier)
                  .reinitializeConvexAuth(source: 'library_retry'),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    return KeyedSubtree(
      key: const ValueKey('library-sign-in-state'),
      child: _LibraryMessageState(
        icon: LucideIcons.logIn,
        iconColor: Settings.tacticalVioletTheme.mutedForeground,
        title: 'Log in to use the web beta',
        subtitle: 'Strategies you make here are saved to your Icarus '
            'account.',
        actions: [
          ShadButton(
            key: const ValueKey('library-sign-in-action'),
            onPressed: () {
              showDialog<void>(
                context: context,
                builder: (_) => const AuthDialog(),
              );
            },
            child: const Text('Log In'),
          ),
        ],
      ),
    );
  }

  Widget _buildCommunityPlaceholder(BuildContext context, WidgetRef ref) {
    return _LibraryMessageState(
      icon: LucideIcons.globe,
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

/// Shown above the My Library root while the cloud half's first fetch is out.
/// The local half is usable underneath.
class _CloudLoadingBanner extends StatelessWidget {
  const _CloudLoadingBanner();

  @override
  Widget build(BuildContext context) {
    return _CloudBanner(
      key: const ValueKey('cloud-loading-banner'),
      leading: Padding(
        padding: const EdgeInsets.all(1.5),
        child: CircularProgressIndicator(
          strokeWidth: 1.8,
          color: Settings.tacticalVioletTheme.mutedForeground,
        ),
      ),
      message: "Loading your cloud library. Showing what's on this computer "
          'for now.',
    );
  }
}

/// Shown above the library while the cloud is out of reach and the cloud
/// half comes from this computer's copy, with when that copy last matched
/// the server.
class _CloudOfflineBanner extends StatelessWidget {
  const _CloudOfflineBanner({required this.matchedAt});

  final DateTime matchedAt;

  @override
  Widget build(BuildContext context) {
    return _CloudBanner(
      key: const ValueKey('cloud-offline-banner'),
      leading: Icon(
        LucideIcons.cloudOff,
        size: 16,
        color: Settings.tacticalVioletTheme.mutedForeground,
      ),
      message: 'Offline. Showing your cloud library as of '
          '${cloudCopyTimeLabel(context, matchedAt, now: DateTime.now())}. '
          "Changes sync when you're back online.",
    );
  }
}

/// [matchedAt] as a time of day, with the date in front when it isn't
/// today.
@visibleForTesting
String cloudCopyTimeLabel(
  BuildContext context,
  DateTime matchedAt, {
  required DateTime now,
}) {
  final localizations = MaterialLocalizations.of(context);
  final local = matchedAt.toLocal();
  final time = localizations.formatTimeOfDay(
    TimeOfDay.fromDateTime(local),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
  final today = now.toLocal();
  final sameDay = local.year == today.year &&
      local.month == today.month &&
      local.day == today.day;
  return sameDay ? time : '${localizations.formatShortMonthDay(local)}, $time';
}

/// Shown above the My Library root when the cloud half failed to load. The
/// local half stays usable underneath.
class _CloudErrorBanner extends StatelessWidget {
  const _CloudErrorBanner({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _CloudBanner(
      key: const ValueKey('cloud-error-banner'),
      leading: Icon(
        LucideIcons.cloudOff,
        size: 16,
        color: Settings.tacticalVioletTheme.destructive,
      ),
      message: "Couldn't load your cloud library. Showing what's on this "
          'computer.',
      action: ShadButton.ghost(
        // The button's usual vertical padding leaves too little of 28 for a
        // line of text, and clips the y of Retry.
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        leading: const Icon(LucideIcons.refreshCw, size: 14),
        onPressed: onRetry,
        child: const Text('Retry'),
      ),
    );
  }
}

/// Shown above the My Library root when the session is signed in but gave up
/// connecting to the cloud. Retry connects again, the way Settings'
/// Reconnect does; a server that refuses this build asks for the update.
class _CloudUnreachableBanner extends ConsumerWidget {
  const _CloudUnreachableBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(clientUpgradeRequiredProvider)) {
      return ClientUpgradeNotice(
        builder: (context, message, action) => _CloudBanner(
          key: const ValueKey('cloud-upgrade-banner'),
          leading: Icon(
            LucideIcons.cloudOff,
            size: 16,
            color: Settings.tacticalVioletTheme.destructive,
          ),
          message: message,
          action: action,
        ),
      );
    }
    return _CloudErrorBanner(
      onRetry: () => ref
          .read(authProvider.notifier)
          .reinitializeConvexAuth(source: 'library_root_retry'),
    );
  }
}

/// The one slot above the My Library root that speaks for the cloud half.
/// Its height doesn't depend on [action], so while the message fits on one
/// line, a load that fails swaps the loading banner for the error one
/// without moving the grid.
class _CloudBanner extends StatelessWidget {
  const _CloudBanner({
    super.key,
    required this.leading,
    required this.message,
    this.action,
  });

  final Widget leading;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        decoration: BoxDecoration(
          color: Settings.tacticalVioletTheme.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Settings.tacticalVioletTheme.border),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 28),
          child: Row(
            children: [
              SizedBox.square(dimension: 16, child: leading),
              const SizedBox(width: 10),
              Expanded(child: Text(message)),
              if (action case final action?) action,
            ],
          ),
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
