import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/update_checker.dart';
import 'package:icarus/main.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/cloud_migration_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_filter_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/update_status_provider.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/current_path_bar.dart';
import 'package:icarus/widgets/custom_search_field.dart';
import 'package:icarus/widgets/demo_dialog.dart';
import 'package:icarus/widgets/demo_tag.dart';
import 'package:icarus/widgets/dialogs/auth/auth_dialog.dart';
import 'package:icarus/widgets/dialogs/confirm_alert_dialog.dart';
import 'package:icarus/widgets/dialogs/strategy/create_strategy_dialog.dart';
import 'package:icarus/widgets/dialogs/web_view_dialog.dart';
import 'package:icarus/widgets/dot_painter.dart';
import 'package:icarus/widgets/folder_edit_dialog.dart';
import 'package:icarus/widgets/folder_pill.dart';
import 'package:icarus/widgets/ica_drop_target.dart';
import 'package:icarus/widgets/library_models.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile_sections.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class FolderNavigator extends ConsumerStatefulWidget {
  const FolderNavigator({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _FolderNavigatorState();
}

class _FolderNavigatorState extends ConsumerState<FolderNavigator> {
  bool _warnedOnce = false;
  bool _hasPromptedUpdateDialog = false;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(ref.read(cloudMigrationProvider.notifier).maybeMigrate());
      if (_warnedOnce) {
        return;
      }
      _warnedOnce = true;
      _warnWebView();
      _warnDemo();
    });
  }

  void _warnWebView() async {
    if (kIsWeb || !Platform.isWindows || isWebViewInitialized) {
      return;
    }
    await showShadDialog<void>(
      context: context,
      builder: (_) => const WebViewDialog(),
    );
  }

  void _warnDemo() async {
    if (!kIsWeb) {
      return;
    }
    await showShadDialog<void>(
      context: context,
      builder: (_) => const DemoDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<UpdateCheckResult>>(appUpdateStatusProvider,
        (_, next) {
      next.whenData((result) {
        if (!mounted || _hasPromptedUpdateDialog || !result.isUpdateAvailable) {
          return;
        }
        _hasPromptedUpdateDialog = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) {
            return;
          }
          UpdateChecker.showUpdateDialog(context, result);
        });
      });
    });

    final double height = MediaQuery.sizeOf(context).height - 90;
    final Size playAreaSize = Size(height * (16 / 9), height);
    CoordinateSystem(playAreaSize: playAreaSize);
    final authState = ref.watch(authProvider);

    Future<void> navigateWithLoading(
      BuildContext context,
      String strategyId,
    ) async {
      try {
        await ref.read(strategyProvider.notifier).openStrategy(strategyId);
        if (!context.mounted) {
          return;
        }
        Navigator.push(
          context,
          PageRouteBuilder(
            transitionDuration: const Duration(milliseconds: 200),
            reverseTransitionDuration: const Duration(milliseconds: 200),
            pageBuilder: (context, animation, secondaryAnimation) =>
                const StrategyView(),
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) {
              return FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1.0)
                      .chain(CurveTween(curve: Curves.easeOut))
                      .animate(animation),
                  child: child,
                ),
              );
            },
          ),
        );
      } catch (_) {}
    }

    void showCreateDialog() async {
      final String? strategyId = await showDialog<String>(
        context: context,
        builder: (_) => const CreateStrategyDialog(),
      );

      if (strategyId != null) {
        if (!context.mounted) {
          return;
        }
        await navigateWithLoading(context, strategyId);
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const CurrentPathBar(),
        toolbarHeight: 70,
        actionsPadding: const EdgeInsets.only(right: 24),
        actions: [
          if (kIsWeb)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: DemoTag(),
            ),
          Row(
            spacing: 15,
            children: [
              ShadButton.secondary(
                onPressed: authState.isLoading
                    ? null
                    : () {
                        if (authState.isAuthenticated) {
                          unawaited(ref.read(authProvider.notifier).signOut());
                        } else {
                          showDialog<void>(
                            context: context,
                            builder: (_) => const AuthDialog(),
                          );
                        }
                      },
                leading: Icon(
                  authState.isAuthenticated ? Icons.logout : Icons.login,
                ),
                child: Text(
                  authState.isLoading
                      ? 'Please wait...'
                      : (authState.isAuthenticated ? 'Sign Out' : 'Log In'),
                ),
              ),
              ShadButton.secondary(
                onPressed: () async {
                  if (kIsWeb) {
                    Settings.showToast(
                      message:
                          'This feature is only supported in the Windows version.',
                      backgroundColor: Settings.tacticalVioletTheme.destructive,
                    );
                    return;
                  }
                  try {
                    await ref
                        .read(strategyProvider.notifier)
                        .loadFromFilePicker();
                  } on NewerVersionImportException {
                    Settings.showToast(
                      message: NewerVersionImportException.userMessage,
                      backgroundColor: Settings.tacticalVioletTheme.destructive,
                    );
                  }
                },
                leading: const Icon(Icons.file_download),
                child: const Text('Import .ica'),
              ),
              ShadButton.secondary(
                leading: const Icon(LucideIcons.folderPlus),
                child: const Text('Add Folder'),
                onPressed: () async {
                  await showDialog<String>(
                    context: context,
                    builder: (_) => const FolderEditDialog(),
                  );
                },
              ),
              ShadButton(
                onPressed: showCreateDialog,
                leading: const Icon(Icons.add),
                child: const Text('Create Strategy'),
              ),
            ],
          ),
        ],
      ),
      body: const FolderContent(),
    );
  }
}

class FolderContent extends ConsumerWidget {
  const FolderContent({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCloud = ref.watch(isCloudCollabEnabledProvider);
    if (isCloud) {
      return const _CloudFolderContent();
    }
    return const _LocalFolderContent();
  }
}

class _CloudFolderContent extends ConsumerWidget {
  const _CloudFolderContent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = ref.watch(cloudFoldersProvider).valueOrNull ?? const [];
    final strategies =
        ref.watch(cloudStrategiesProvider).valueOrNull ?? const [];
    final currentFolderId = ref.watch(folderProvider);
    final search = ref.watch(strategySearchQueryProvider).trim().toLowerCase();
    final filter = ref.watch(strategyFilterProvider);

    var visibleFolders = folders;
    var visibleStrategies = strategies;

    if (search.isNotEmpty) {
      visibleFolders = visibleFolders
          .where((folder) => folder.name.toLowerCase().contains(search))
          .toList(growable: false);
      visibleStrategies = visibleStrategies
          .where((strategy) => strategy.name.toLowerCase().contains(search))
          .toList(growable: false);
    }

    Comparator<CloudStrategySummary> comparator = switch (filter.sortBy) {
      SortBy.alphabetical => (a, b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      SortBy.dateCreated => (a, b) => a.createdAt.compareTo(b.createdAt),
      SortBy.dateUpdated => (a, b) => a.updatedAt.compareTo(b.updatedAt),
    };

    final direction = filter.sortOrder == SortOrder.ascending ? 1 : -1;
    visibleStrategies = [...visibleStrategies]
      ..sort((a, b) => direction * comparator(a, b));
    visibleFolders = [...visibleFolders]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    final folderEntries = visibleFolders
        .map(
          (folder) => _FolderEntry(
            data: LibraryFolderItemData(
              id: folder.publicId,
              name: folder.name,
              icon: Folder.iconFromIndex(folder.iconIndex),
              backgroundColor: Folder.customColorFromValue(
                      folder.customColorValue) ??
                  Folder.folderColorMap[Folder.colorFromKey(folder.colorKey)] ??
                  Colors.grey,
            ),
            onOpen: () =>
                ref.read(folderProvider.notifier).updateID(folder.publicId),
            onEdit: () => showDialog<String>(
              context: context,
              builder: (_) => FolderEditDialog(
                folderId: folder.publicId,
                initialName: folder.name,
                initialIcon: Folder.iconFromIndex(folder.iconIndex),
                initialColor: Folder.colorFromKey(folder.colorKey),
                initialCustomColor:
                    Folder.customColorFromValue(folder.customColorValue),
              ),
            ),
            onDelete: () => _confirmDeleteFolder(
                context, ref, folder.name, folder.publicId),
          ),
        )
        .toList(growable: false);

    final strategyEntries = visibleStrategies
        .map(
          (strategy) => _StrategyEntry(
            strategyId: strategy.publicId,
            currentName: strategy.name,
            data: StrategyTileDataFactory.fromCloud(
              id: strategy.publicId,
              name: strategy.name,
              mapData: strategy.mapData,
              updatedAt: strategy.updatedAt,
            ),
            canRename: strategy.role == 'editor' || strategy.role == 'owner',
            canDuplicate: true,
            canExport: true,
            canDelete: strategy.role == 'owner',
          ),
        )
        .toList(growable: false);

    return _SharedFolderContent(
      folderEntries: folderEntries,
      strategyEntries: strategyEntries,
      isRoot: currentFolderId == null,
    );
  }
}

class _LocalFolderContent extends ConsumerWidget {
  const _LocalFolderContent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strategyBox = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final folderBox = Hive.box<Folder>(HiveBoxNames.foldersBox);
    final currentFolderId = ref.watch(folderProvider);

    return ValueListenableBuilder<Box<StrategyData>>(
      valueListenable: strategyBox.listenable(),
      builder: (context, strategiesListenable, _) {
        return ValueListenableBuilder<Box<Folder>>(
          valueListenable: folderBox.listenable(),
          builder: (context, foldersListenable, __) {
            final search =
                ref.watch(strategySearchQueryProvider).trim().toLowerCase();
            final filter = ref.watch(strategyFilterProvider);

            var folders = foldersListenable.values
                .where((folder) => folder.parentID == currentFolderId)
                .toList(growable: false);

            var strategies = strategiesListenable.values
                .where((strategy) => strategy.folderID == currentFolderId)
                .toList(growable: false);

            if (search.isNotEmpty) {
              folders = folders
                  .where((folder) => folder.name.toLowerCase().contains(search))
                  .toList(growable: false);
              strategies = strategies
                  .where((strategy) =>
                      strategy.name.toLowerCase().contains(search))
                  .toList(growable: false);
            }

            Comparator<StrategyData> comparator = switch (filter.sortBy) {
              SortBy.alphabetical => (a, b) =>
                  a.name.toLowerCase().compareTo(b.name.toLowerCase()),
              SortBy.dateCreated => (a, b) =>
                  a.createdAt.compareTo(b.createdAt),
              SortBy.dateUpdated => (a, b) =>
                  a.lastEdited.compareTo(b.lastEdited),
            };

            final direction = filter.sortOrder == SortOrder.ascending ? 1 : -1;
            strategies = [...strategies]
              ..sort((a, b) => direction * comparator(a, b));
            folders = [...folders]
              ..sort((a, b) => a.dateCreated.compareTo(b.dateCreated));

            final folderEntries = folders
                .map(
                  (folder) => _FolderEntry(
                    data: LibraryFolderItemData(
                      id: folder.id,
                      name: folder.name,
                      icon: folder.icon,
                      backgroundColor: folder.customColor ??
                          Folder.folderColorMap[folder.color] ??
                          Colors.grey,
                    ),
                    onOpen: () =>
                        ref.read(folderProvider.notifier).updateID(folder.id),
                    onEdit: () => showDialog<String>(
                      context: context,
                      builder: (_) => FolderEditDialog(folder: folder),
                    ),
                    onExport: () async {
                      await ref
                          .read(strategyProvider.notifier)
                          .exportFolder(folder.id);
                    },
                    onDelete: () => _confirmDeleteFolder(
                        context, ref, folder.name, folder.id),
                  ),
                )
                .toList(growable: false);

            final strategyEntries = strategies
                .map(
                  (strategy) => _StrategyEntry(
                    strategyId: strategy.id,
                    currentName: strategy.name,
                    data: StrategyTileDataFactory.fromLocal(strategy),
                    canRename: true,
                    canDuplicate: true,
                    canExport: true,
                    canDelete: true,
                  ),
                )
                .toList(growable: false);

            return _SharedFolderContent(
              folderEntries: folderEntries,
              strategyEntries: strategyEntries,
              isRoot: currentFolderId == null,
            );
          },
        );
      },
    );
  }
}

class _SharedFolderContent extends StatelessWidget {
  const _SharedFolderContent({
    required this.folderEntries,
    required this.strategyEntries,
    required this.isRoot,
  });

  final List<_FolderEntry> folderEntries;
  final List<_StrategyEntry> strategyEntries;
  final bool isRoot;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(
          child: Padding(
            padding: EdgeInsets.all(4),
            child: DotGrid(),
          ),
        ),
        Positioned.fill(
          child: Column(
            children: [
              const _FolderToolbar(),
              Expanded(
                child: IcaDropTarget(
                  child: CustomScrollView(
                    slivers: [
                      if (folderEntries.isNotEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                            child: Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: [
                                for (final folder in folderEntries)
                                  FolderPill(
                                    data: folder.data,
                                    onOpen: folder.onOpen,
                                    onEdit: folder.onEdit,
                                    onExport: folder.onExport,
                                    onDelete: folder.onDelete,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      if (strategyEntries.isNotEmpty)
                        SliverPadding(
                          padding: const EdgeInsets.all(16),
                          sliver: SliverGrid(
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 320,
                              mainAxisExtent: 250,
                              crossAxisSpacing: 20,
                              mainAxisSpacing: 20,
                            ),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                final entry = strategyEntries[index];
                                return StrategyTile(
                                  strategyId: entry.strategyId,
                                  currentName: entry.currentName,
                                  data: entry.data,
                                  canRename: entry.canRename,
                                  canDuplicate: entry.canDuplicate,
                                  canExport: entry.canExport,
                                  canDelete: entry.canDelete,
                                );
                              },
                              childCount: strategyEntries.length,
                            ),
                          ),
                        )
                      else
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: isRoot
                                ? const Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text('No strategies available'),
                                      Text(
                                          'Create a new strategy or drop an .ica file'),
                                    ],
                                  )
                                : const Text('No strategies in this folder'),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FolderToolbar extends ConsumerWidget {
  const _FolderToolbar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, left: 16, right: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              ShadSelect<SortBy>(
                decoration: ShadDecoration(
                  color: Settings.tacticalVioletTheme.card,
                  shadows: const [Settings.cardForegroundBackdrop],
                ),
                initialValue: ref.watch(strategyFilterProvider).sortBy,
                selectedOptionBuilder: (context, value) =>
                    Text(StrategyFilterProvider.sortByLabels[value]!),
                options: [
                  for (final value in SortBy.values)
                    ShadOption(
                      value: value,
                      child: Text(StrategyFilterProvider.sortByLabels[value]!),
                    ),
                ],
                onChanged: (value) =>
                    ref.read(strategyFilterProvider.notifier).setSortBy(value!),
              ),
              const SizedBox(width: 8),
              ShadSelect<SortOrder>(
                decoration: ShadDecoration(
                  color: Settings.tacticalVioletTheme.card,
                  shadows: const [Settings.cardForegroundBackdrop],
                ),
                initialValue: ref.watch(strategyFilterProvider).sortOrder,
                selectedOptionBuilder: (context, value) =>
                    Text(StrategyFilterProvider.sortOrderLabels[value]!),
                options: [
                  for (final value in SortOrder.values)
                    ShadOption(
                      value: value,
                      child:
                          Text(StrategyFilterProvider.sortOrderLabels[value]!),
                    ),
                ],
                onChanged: (value) => ref
                    .read(strategyFilterProvider.notifier)
                    .setSortOrder(value!),
              ),
            ],
          ),
          const SizedBox(
            height: 40,
            child: SearchTextField(
              collapsedWidth: 40,
              expandedWidth: 250,
              compact: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _FolderEntry {
  const _FolderEntry({
    required this.data,
    required this.onOpen,
    this.onEdit,
    this.onExport,
    this.onDelete,
  });

  final LibraryFolderItemData data;
  final VoidCallback onOpen;
  final VoidCallback? onEdit;
  final VoidCallback? onExport;
  final VoidCallback? onDelete;
}

class _StrategyEntry {
  const _StrategyEntry({
    required this.strategyId,
    required this.currentName,
    required this.data,
    required this.canRename,
    required this.canDuplicate,
    required this.canExport,
    required this.canDelete,
  });

  final String strategyId;
  final String currentName;
  final LibraryStrategyItemData data;
  final bool canRename;
  final bool canDuplicate;
  final bool canExport;
  final bool canDelete;
}

Future<void> _confirmDeleteFolder(
  BuildContext context,
  WidgetRef ref,
  String folderName,
  String folderId,
) async {
  final confirmed = await ConfirmAlertDialog.show(
    context: context,
    title: "Are you sure you want to delete '$folderName' folder?",
    content: 'This will also delete all strategies and subfolders within it.',
    confirmText: 'Delete',
    isDestructive: true,
  );

  if (confirmed == true) {
    ref.read(folderProvider.notifier).deleteFolder(folderId);
  }
}
