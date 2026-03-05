import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/update_checker.dart';
import 'package:icarus/main.dart';
import 'package:icarus/providers/collab/cloud_migration_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/update_status_provider.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/current_path_bar.dart';
import 'package:icarus/widgets/demo_dialog.dart';
import 'package:icarus/widgets/demo_tag.dart';
import 'package:icarus/widgets/dialogs/strategy/create_strategy_dialog.dart';
import 'package:icarus/widgets/dialogs/web_view_dialog.dart';
import 'package:icarus/widgets/folder_edit_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/strategy_filter_provider.dart';
import 'package:icarus/widgets/custom_search_field.dart';
import 'package:icarus/widgets/dot_painter.dart';
import 'package:icarus/widgets/folder_pill.dart';
import 'package:icarus/widgets/ica_drop_target.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile.dart';

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

    // Show the demo warning only once after the first frame on web.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(ref.read(cloudMigrationProvider.notifier).maybeMigrate());
      if (!_warnedOnce) {
        _warnedOnce = true;

        log("Warning webview");
        _warnWebView();

        _warnDemo();
      }
    });
  }

  void _warnWebView() async {
    if (kIsWeb) return;
    if (!Platform.isWindows) return;
    if (isWebViewInitialized) return;
    await showShadDialog<void>(
      context: context,
      builder: (context) {
        return const WebViewDialog();
      },
    );
  }

  void _warnDemo() async {
    if (!kIsWeb) return;
    await showShadDialog<void>(
      context: context,
      builder: (context) {
        return const DemoDialog();
      },
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
          if (!mounted) return;
          UpdateChecker.showUpdateDialog(context, result);
        });
      });
    });

    final double height = MediaQuery.sizeOf(context).height - 90;
    final Size playAreaSize = Size(height * (16 / 9), height);
    CoordinateSystem(playAreaSize: playAreaSize);
    final currentFolderId = ref.watch(folderProvider);
    final currentFolder = currentFolderId != null
        ? ref.read(folderProvider.notifier).findFolderByID(currentFolderId)
        : null;
    final authState = ref.watch(authProvider);
    Future<void> navigateWithLoading(
        BuildContext context, String strategyId) async {
      // Show loading overlay
      // showLoadingOverlay(context);

      try {
        await ref.read(strategyProvider.notifier).openStrategy(strategyId);

        if (!context.mounted) return;

        Navigator.push(
          context,
          PageRouteBuilder(
            transitionDuration: const Duration(milliseconds: 200),
            reverseTransitionDuration:
                const Duration(milliseconds: 200), // pop duration
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
      } catch (e) {
        // Handle errors
        // Show error message
      }
    }

    void showCreateDialog() async {
      final String? strategyId = await showDialog<String>(
        context: context,
        builder: (context) {
          return const CreateStrategyDialog();
        },
      );

      if (strategyId != null) {
        if (!context.mounted) return;
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
              padding: EdgeInsets.symmetric(horizontal: 8.0),
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
                          unawaited(
                              ref.read(authProvider.notifier).signInWithDiscord());
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
                    builder: (context) {
                      return const FolderEditDialog();
                    },
                  );
                },
              ),
              ShadButton(
                onPressed: showCreateDialog,
                leading: const Icon(Icons.add),
                child: const Text('Create Strategy'),
              ),
            ],
          )
        ],
        // ... your existing actions
      ),
      body: FolderContent(folder: currentFolder),
    );
  }
}

sealed class GridItem {}

class FolderItem extends GridItem {
  final Folder folder;

  FolderItem(this.folder);
}

class StrategyItem extends GridItem {
  final StrategyData strategy;

  StrategyItem(this.strategy);
}

class FolderContent extends ConsumerWidget {
  const FolderContent({super.key, this.folder});

  final Folder? folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCloud = ref.watch(isCloudCollabEnabledProvider);
    if (isCloud) {
      return _CloudFolderContent(folder: folder);
    }
    return _LocalFolderContent(folder: folder);
  }
}

class _CloudFolderContent extends ConsumerWidget {
  const _CloudFolderContent({this.folder});

  final Folder? folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final foldersAsync = ref.watch(cloudFoldersProvider);
    final strategiesAsync = ref.watch(cloudStrategiesProvider);
    final search = ref.watch(strategySearchQueryProvider).trim().toLowerCase();
    final filter = ref.watch(strategyFilterProvider);

    final folders = foldersAsync.valueOrNull ?? const <CloudFolderSummary>[];
    var strategies =
        strategiesAsync.valueOrNull ?? const <CloudStrategySummary>[];

    if (search.isNotEmpty) {
      strategies = strategies
          .where((strategy) => strategy.name.toLowerCase().contains(search))
          .toList(growable: false);
    }

    Comparator<CloudStrategySummary> comparator = switch (filter.sortBy) {
      SortBy.alphabetical =>
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      SortBy.dateCreated => (a, b) => a.createdAt.compareTo(b.createdAt),
      SortBy.dateUpdated => (a, b) => a.updatedAt.compareTo(b.updatedAt),
    };

    final direction = filter.sortOrder == SortOrder.ascending ? 1 : -1;
    strategies = [...strategies]..sort((a, b) => direction * comparator(a, b));

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
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (folders.isNotEmpty)
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            for (final cloudFolder in folders)
                              ActionChip(
                                label: Text(cloudFolder.name),
                                onPressed: () {
                                  ref
                                      .read(folderProvider.notifier)
                                      .updateID(cloudFolder.publicId);
                                },
                              ),
                          ],
                        ),
                      if (folders.isNotEmpty) const SizedBox(height: 16),
                      if (strategies.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 24),
                          child: Center(
                            child: Text('No cloud strategies in this folder'),
                          ),
                        ),
                      for (final strategy in strategies)
                        Card(
                          color: Settings.tacticalVioletTheme.card,
                          margin: const EdgeInsets.only(bottom: 12),
                          child: ListTile(
                            title: Text(strategy.name),
                            subtitle: Text(
                              '${strategy.mapData} • Updated ${strategy.updatedAt.toLocal()}',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () async {
                              await ref
                                  .read(strategyProvider.notifier)
                                  .openStrategy(strategy.publicId);
                              if (!context.mounted) return;
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const StrategyView(),
                                ),
                              );
                            },
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

class _LocalFolderContent extends ConsumerWidget {
  const _LocalFolderContent({this.folder});

  final Folder? folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strategyBox = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final folderBox = Hive.box<Folder>(HiveBoxNames.foldersBox);

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
                child: ValueListenableBuilder<Box<StrategyData>>(
                  valueListenable: strategyBox.listenable(),
                  builder: (context, strategiesListenable, _) {
                    return ValueListenableBuilder<Box<Folder>>(
                      valueListenable: folderBox.listenable(),
                      builder: (context, foldersListenable, __) {
                        final search = ref
                            .watch(strategySearchQueryProvider)
                            .trim()
                            .toLowerCase();
                        final filter = ref.watch(strategyFilterProvider);

                        final folders = foldersListenable.values
                            .where((f) => f.parentID == folder?.id)
                            .toList(growable: false);

                        var strategies = strategiesListenable.values
                            .where((s) => s.folderID == folder?.id)
                            .toList(growable: false);

                        if (search.isNotEmpty) {
                          strategies = strategies
                              .where((s) =>
                                  s.name.toLowerCase().contains(search))
                              .toList(growable: false);
                        }

                        Comparator<StrategyData> comparator =
                            switch (filter.sortBy) {
                          SortBy.alphabetical => (a, b) =>
                            a.name.toLowerCase().compareTo(b.name.toLowerCase()),
                          SortBy.dateCreated =>
                            (a, b) => a.createdAt.compareTo(b.createdAt),
                          SortBy.dateUpdated =>
                            (a, b) => a.lastEdited.compareTo(b.lastEdited),
                        };
                        final direction =
                            filter.sortOrder == SortOrder.ascending ? 1 : -1;
                        strategies = [...strategies]
                          ..sort((a, b) => direction * comparator(a, b));

                        return IcaDropTarget(
                          child: CustomScrollView(
                            slivers: [
                              if (folders.isNotEmpty)
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                        16, 16, 16, 8),
                                    child: Wrap(
                                      spacing: 10,
                                      runSpacing: 10,
                                      children: folders
                                          .map((f) => FolderPill(folder: f))
                                          .toList(growable: false),
                                    ),
                                  ),
                                ),
                              if (strategies.isNotEmpty)
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
                                        return StrategyTile(
                                            strategyData: strategies[index]);
                                      },
                                      childCount: strategies.length,
                                    ),
                                  ),
                                )
                              else
                                const SliverFillRemaining(
                                  hasScrollBody: false,
                                  child: Center(
                                    child: Text('No strategies in this folder'),
                                  ),
                                ),
                            ],
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
                onChanged: (value) => ref
                    .read(strategyFilterProvider.notifier)
                    .setSortBy(value!),
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





