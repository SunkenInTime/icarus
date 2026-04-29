import 'dart:async';

import 'package:desktop_updater/desktop_updater.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/update_checker.dart';
import 'package:icarus/main.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/providers/update_status_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/services/windows_desktop_update_controller.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/current_path_bar.dart';
import 'package:icarus/widgets/desktop_update_dialog.dart';
import 'package:icarus/widgets/demo_dialog.dart';
import 'package:icarus/widgets/demo_tag.dart';
import 'package:icarus/widgets/dialogs/auth/auth_dialog.dart';
import 'package:icarus/widgets/dialogs/strategy/create_strategy_dialog.dart';
import 'package:icarus/widgets/dialogs/web_view_dialog.dart';
import 'package:icarus/widgets/folder_content.dart';
import 'package:icarus/widgets/folder_edit_dialog.dart';
import 'package:icarus/widgets/ica_drop_target.dart';
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
  WindowsDesktopUpdateController? _desktopUpdaterController;
  final GlobalKey _importExportButtonKey = GlobalKey();
  final ShadPopoverController _importExportPopoverController =
      ShadPopoverController();

  bool get _isWindowsDesktop =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  @override
  void dispose() {
    _importExportPopoverController.dispose();
    _desktopUpdaterController?.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();

    // Show the demo warning only once after the first frame on web.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_warnedOnce) {
        _warnedOnce = true;

        _warnWebView();

        _warnDemo();
      }
    });
  }

  void _warnWebView() async {
    if (kIsWeb) return;
    if (!_isWindowsDesktop) return;
    await warmUpWebViewEnvironment();
    if (!mounted) return;
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

  void _showDesktopOnlyToast() {
    Settings.showToast(
      message: 'This feature is only supported in the Windows version.',
      backgroundColor: Settings.tacticalVioletTheme.destructive,
    );
  }

  void _toggleImportExportPopover() {
    _importExportPopoverController.toggle();
  }

  Future<void> handleImportIca() async {
    if (kIsWeb) {
      _showDesktopOnlyToast();
      return;
    }
    try {
      await StrategyImportExportService(ref).loadFromFilePicker();
    } on NewerVersionImportException catch (error, stackTrace) {
      AppErrorReporter.reportError(
        NewerVersionImportException.userMessage,
        error: error,
        stackTrace: stackTrace,
        source: 'FolderNavigator.handleImportIca',
      );
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        'Failed to import strategy file.',
        error: error,
        stackTrace: stackTrace,
        source: 'FolderNavigator.handleImportIca',
      );
    }
  }

  Future<void> handleImportBackup() async {
    if (kIsWeb) {
      _showDesktopOnlyToast();
      return;
    }
    try {
      final result =
          await StrategyImportExportService(ref).importBackupFromFilePicker();
      if (result.hasImports || result.issues.isNotEmpty) {
        final message = buildImportSummaryMessage(result);
        if (result.hasImports) {
          Settings.showToast(
            message: message,
            backgroundColor: Settings.tacticalVioletTheme.primary,
          );
          if (result.issues.isNotEmpty) {
            AppErrorReporter.reportWarning(
              message,
              source: 'FolderNavigator.handleImportBackup',
            );
          }
        } else {
          AppErrorReporter.reportError(
            message,
            source: 'FolderNavigator.handleImportBackup',
          );
        }
      }
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        'Failed to import backup archive.',
        error: error,
        stackTrace: stackTrace,
        source: 'FolderNavigator.handleImportBackup',
      );
    }
  }

  Future<void> handleExportLibrary() async {
    if (kIsWeb) {
      _showDesktopOnlyToast();
      return;
    }
    try {
      await StrategyImportExportService(ref).exportLibrary();
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        'Failed to export library.',
        error: error,
        stackTrace: stackTrace,
        source: 'FolderNavigator.handleExportLibrary',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<UpdateCheckResult>>(appUpdateStatusProvider,
        (_, next) {
      next.whenData((result) {
        if (!mounted) {
          return;
        }

        final bool isDirectWindowsInstall =
            _isWindowsDesktop && !result.isSupported;
        if (isDirectWindowsInstall && _desktopUpdaterController == null) {
          _desktopUpdaterController = WindowsDesktopUpdateController(
            appArchiveUrl: Settings.desktopUpdaterArchiveUrl,
            localization: const DesktopUpdateLocalization(
              updateAvailableText: 'Update Available',
              newVersionAvailableText: '{} {} is available',
              newVersionLongText:
                  'A desktop update is ready. Downloading will fetch {} MB of files.',
              downloadText: 'Download Update',
              restartText: 'Restart to update',
              skipThisVersionText: 'Later',
              warningTitleText: 'Restart Required',
              restartWarningText:
                  'Icarus needs to restart to finish installing the update. Unsaved changes will be lost. Restart now?',
              warningCancelText: 'Not now',
              warningConfirmText: 'Restart',
            ),
          );
          setState(() {});
        }

        if (_hasPromptedUpdateDialog || !result.isUpdateAvailable) {
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
    final workspace = ref.watch(libraryWorkspaceProvider);
    final isCloudWorkspace = workspace == LibraryWorkspace.cloud;
    final isCommunityWorkspace = workspace == LibraryWorkspace.community;
    final currentFolderId = ref.watch(folderProvider);
    final currentFolder = currentFolderId != null
        ? isCloudWorkspace
            ? ref.read(folderProvider.notifier).findCloudFolderByID(
                  currentFolderId,
                  ref.watch(cloudAllFoldersProvider).valueOrNull ?? const [],
                )
            : ref
                .read(folderProvider.notifier)
                .findLocalFolderByID(currentFolderId)
        : null;
    Future<void> navigateWithLoading(
        BuildContext context, String strategyId) async {
      // Show loading overlay
      // showLoadingOverlay(context);

      try {
        await ref.read(strategyProvider.notifier).loadFromHive(strategyId);

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
        if (isCloudWorkspace) {
          await Navigator.push(
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
        } else {
          await navigateWithLoading(context, strategyId);
        }
      }
    }

    const double railReservedWidth = 64;

    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            title: const Padding(
              padding: EdgeInsets.only(left: railReservedWidth),
              child: CurrentPathBar(),
            ),
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
                  ShadPopover(
                    controller: _importExportPopoverController,
                    padding: const EdgeInsets.all(8),
                    anchor: const ShadAnchor(
                      offset: Offset(0, 8),
                      childAlignment: Alignment.topLeft,
                      overlayAlignment: Alignment.bottomLeft,
                    ),
                    popover: (context) {
                      return SizedBox(
                        width: 178,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ShadButton.ghost(
                              onPressed: handleImportIca,
                              mainAxisAlignment: MainAxisAlignment.start,
                              leading: const Icon(
                                Icons.file_download,
                              ),
                              child: const Text(
                                'Import .ica',
                                style: TextStyle(color: Colors.white),
                              ),
                            ),
                            ShadButton.ghost(
                              onPressed: handleImportBackup,
                              mainAxisAlignment: MainAxisAlignment.start,
                              leading: const Icon(
                                Icons.archive_outlined,
                              ),
                              child: const Text('Import Backup',
                                  style: TextStyle(color: Colors.white)),
                            ),
                            ShadButton.ghost(
                              onPressed: handleExportLibrary,
                              mainAxisAlignment: MainAxisAlignment.start,
                              leading: const Icon(
                                Icons.backup_outlined,
                              ),
                              child: const Text('Export Library',
                                  style: TextStyle(color: Colors.white)),
                            ),
                          ],
                        ),
                      );
                    },
                    child: ShadButton.secondary(
                      key: _importExportButtonKey,
                      onPressed: isCloudWorkspace || isCommunityWorkspace
                          ? null
                          : _toggleImportExportPopover,
                      leading: const Icon(Icons.import_export),
                      trailing: const Icon(Icons.keyboard_arrow_down),
                      child: const Text('Import / Export'),
                    ),
                  ),
                  ShadButton.secondary(
                    leading: const Icon(LucideIcons.folderPlus),
                    onPressed: isCommunityWorkspace
                        ? null
                        : () async {
                            await showDialog<String>(
                              context: context,
                              builder: (context) {
                                return const FolderEditDialog();
                              },
                            );
                          },
                    child: const Text('Add Folder'),
                  ),
                  ShadButton(
                    onPressed: isCommunityWorkspace ? null : showCreateDialog,
                    leading: const Icon(Icons.add),
                    child: Text(
                      isCloudWorkspace
                          ? 'Create Cloud Strategy'
                          : 'Create Strategy',
                    ),
                  ),
                ],
              )
            ],
            // ... your existing actions
          ),
          body: Padding(
            padding: const EdgeInsets.only(left: railReservedWidth),
            child: FolderContent(folder: currentFolder),
          ),
        ),
        const Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          child: LibraryNavigationRail(),
        ),
        if (_desktopUpdaterController != null)
          DesktopUpdateDialogListener(
            controller: _desktopUpdaterController!,
          ),
      ],
    );
  }
}

sealed class GridItem {}

class FolderItem extends GridItem {
  final Folder folder;

  FolderItem(this.folder);
}

class StrategyItem extends GridItem {
  final String strategyId;
  final StrategyData? strategy;

  StrategyItem.local(this.strategy) : strategyId = strategy!.id;

  StrategyItem.cloud(this.strategyId) : strategy = null;
}

class LibraryNavigationRail extends ConsumerStatefulWidget {
  const LibraryNavigationRail({super.key});

  @override
  ConsumerState<LibraryNavigationRail> createState() =>
      _LibraryNavigationRailState();
}

class _LibraryNavigationRailState extends ConsumerState<LibraryNavigationRail> {
  static const _closeDelay = Duration(milliseconds: 120);
  static const _detailsDelay = Duration(milliseconds: 190);

  bool _expanded = false;
  bool _showExpandedContent = false;
  Timer? _closeTimer;

  @override
  void dispose() {
    _closeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final workspace = ref.watch(libraryWorkspaceProvider);
    final cloudSection = ref.watch(cloudLibrarySectionProvider);
    final cloudAvailable = ref.watch(isCloudWorkspaceAvailableProvider);
    final authState = ref.watch(authProvider);

    final items = [
      _LibraryRailItemData(
        icon: LucideIcons.monitor,
        label: 'This Computer',
        description: 'Local strategies and imports',
        selected: workspace == LibraryWorkspace.local,
        onTap: () => _selectLocal(),
      ),
      _LibraryRailItemData(
        icon: LucideIcons.cloud,
        label: 'Cloud',
        description: cloudAvailable
            ? 'Your online strategies'
            : 'Log in to sync strategies',
        selected: workspace == LibraryWorkspace.cloud &&
            cloudSection == CloudLibrarySection.home,
        onTap: cloudAvailable ? () => _selectCloudHome() : null,
      ),
      _LibraryRailItemData(
        icon: LucideIcons.users,
        label: 'Shared',
        description: cloudAvailable
            ? 'Strategies shared with you'
            : 'Log in to view shared strats',
        selected: workspace == LibraryWorkspace.cloud &&
            cloudSection == CloudLibrarySection.sharedWithMe,
        onTap: cloudAvailable ? () => _selectShared() : null,
      ),
      _LibraryRailItemData(
        icon: Icons.public,
        label: 'Community',
        description: 'Public strategy library',
        selected: workspace == LibraryWorkspace.community,
        onTap: () => _selectCommunity(),
      ),
    ];

    return MouseRegion(
      onEnter: (_) {
        _closeTimer?.cancel();
        setState(() => _expanded = true);
        Future.delayed(_detailsDelay, () {
          if (!mounted || !_expanded) {
            return;
          }
          setState(() => _showExpandedContent = true);
        });
      },
      onExit: (_) {
        _closeTimer?.cancel();
        _closeTimer = Timer(_closeDelay, () {
          if (!mounted) {
            return;
          }
          setState(() {
            _showExpandedContent = false;
            _expanded = false;
          });
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        width: _expanded ? 226 : 64,
        margin: EdgeInsets.zero,
        decoration: BoxDecoration(
          color: Settings.tacticalVioletTheme.card.withValues(alpha: 0.96),
          borderRadius: const BorderRadius.only(
              // topRight: Radius.circular(14),
              // bottomRight: Radius.circular(14),
              ),
          border: Border.all(color: Settings.tacticalVioletTheme.border),
          boxShadow: const [Settings.cardForegroundBackdrop],
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.only(
              // topRight: Radius.circular(14),
              // bottomRight: Radius.circular(14),
              ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
                child: _RailHeader(
                  expanded: _expanded,
                  showDetails: _showExpandedContent,
                ),
              ),
              Divider(height: 1, color: Settings.tacticalVioletTheme.border),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
                  child: Column(
                    children: [
                      for (final item in items) ...[
                        _LibraryRailItem(
                          data: item,
                          expanded: _expanded,
                          showDetails: _showExpandedContent,
                        ),
                        const SizedBox(height: 8),
                      ],
                      const Spacer(),
                      _AccountRailItem(
                        expanded: _expanded,
                        showDetails: _showExpandedContent,
                        isLoading: authState.isLoading,
                        isAuthenticated: authState.isAuthenticated,
                        avatarUrl: authState.avatarUrl,
                        label: authState.isAuthenticated
                            ? authState.displayName
                            : 'Log In',
                        onAuthAction: authState.isLoading
                            ? null
                            : () {
                                if (authState.isAuthenticated) {
                                  unawaited(
                                    ref.read(authProvider.notifier).signOut(),
                                  );
                                } else {
                                  showDialog<void>(
                                    context: context,
                                    builder: (_) => const AuthDialog(),
                                  );
                                }
                              },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _selectLocal() {
    ref.read(libraryWorkspaceProvider.notifier).select(LibraryWorkspace.local);
    ref.read(folderProvider.notifier).updateID(null);
  }

  void _selectCloudHome() {
    ref.read(libraryWorkspaceProvider.notifier).select(LibraryWorkspace.cloud);
    ref
        .read(cloudLibrarySectionProvider.notifier)
        .select(CloudLibrarySection.home);
    ref.read(folderProvider.notifier).updateID(null);
  }

  void _selectShared() {
    ref.read(libraryWorkspaceProvider.notifier).select(LibraryWorkspace.cloud);
    ref
        .read(cloudLibrarySectionProvider.notifier)
        .select(CloudLibrarySection.sharedWithMe);
    ref.read(folderProvider.notifier).updateID(null);
  }

  void _selectCommunity() {
    ref
        .read(libraryWorkspaceProvider.notifier)
        .select(LibraryWorkspace.community);
    ref.read(folderProvider.notifier).updateID(null);
  }
}

class _RailHeader extends StatelessWidget {
  const _RailHeader({
    required this.expanded,
    required this.showDetails,
  });

  final bool expanded;
  final bool showDetails;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showLabel = showDetails && constraints.maxWidth >= 96;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 48,
                child: Center(
                  child: SizedBox(
                    width: 32,
                    height: 32,
                    child: Image.asset(
                      'assets/icarus-icon.webp',
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                left: 50,
                child: IgnorePointer(
                  ignoring: !showLabel,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 120),
                    opacity: expanded && showLabel ? 1 : 0,
                    child: const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Icarus',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LibraryRailItemData {
  const _LibraryRailItemData({
    required this.icon,
    required this.label,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String description;
  final bool selected;
  final VoidCallback? onTap;
}

class _LibraryRailItem extends StatelessWidget {
  const _LibraryRailItem({
    required this.data,
    required this.expanded,
    required this.showDetails,
  });

  final _LibraryRailItemData data;
  final bool expanded;
  final bool showDetails;

  @override
  Widget build(BuildContext context) {
    final selectedColor =
        Settings.tacticalVioletTheme.primary.withValues(alpha: 0.18);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        mouseCursor: data.onTap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        onTap: data.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: data.selected ? selectedColor : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: data.selected
                  ? Settings.tacticalVioletTheme.primary
                  : Colors.transparent,
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final showLabel = showDetails && constraints.maxWidth >= 96;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: 26,
                    child: Align(
                      alignment: Alignment.center,
                      child: Icon(
                        data.icon,
                        size: 21,
                        color: data.onTap == null
                            ? Settings.tacticalVioletTheme.mutedForeground
                            : null,
                      ),
                    ),
                  ),
                  Positioned.fill(
                    left: 33,
                    child: IgnorePointer(
                      ignoring: !showLabel,
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 120),
                        opacity: expanded && showLabel ? 1 : 0,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              data.label,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              data.description,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Settings
                                    .tacticalVioletTheme.mutedForeground,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _AccountRailItem extends StatelessWidget {
  const _AccountRailItem({
    required this.expanded,
    required this.showDetails,
    required this.isLoading,
    required this.isAuthenticated,
    required this.avatarUrl,
    required this.label,
    required this.onAuthAction,
  });

  final bool expanded;
  final bool showDetails;
  final bool isLoading;
  final bool isAuthenticated;
  final String? avatarUrl;
  final String label;
  final VoidCallback? onAuthAction;

  @override
  Widget build(BuildContext context) {
    final showExpandedLayout = expanded && showDetails;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        mouseCursor: onAuthAction == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        onTap: showExpandedLayout ? null : onAuthAction,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: Settings.tacticalVioletTheme.secondary.withValues(
              alpha: 0.5,
            ),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Settings.tacticalVioletTheme.border),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final showLabel = showDetails && constraints.maxWidth >= 96;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: 28,
                    child: Align(
                      alignment: Alignment.center,
                      child: _AccountAvatar(
                        avatarUrl: avatarUrl,
                        isAuthenticated: isAuthenticated,
                      ),
                    ),
                  ),
                  Positioned.fill(
                    left: 38,
                    child: IgnorePointer(
                      ignoring: !showLabel,
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 120),
                        curve: Curves.easeOutCubic,
                        opacity: expanded && showLabel ? 1 : 0,
                        child: showLabel
                            ? Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      isLoading ? 'Please wait...' : label,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _AccountAvatar extends StatelessWidget {
  const _AccountAvatar({
    required this.avatarUrl,
    required this.isAuthenticated,
  });

  final String? avatarUrl;
  final bool isAuthenticated;

  @override
  Widget build(BuildContext context) {
    if (isAuthenticated && avatarUrl != null) {
      return CircleAvatar(
        radius: 14,
        backgroundImage: NetworkImage(avatarUrl!),
      );
    }

    return CircleAvatar(
      radius: 14,
      backgroundColor: Settings.tacticalVioletTheme.card,
      child: Icon(
        isAuthenticated ? Icons.person : LucideIcons.userRound,
        size: 15,
      ),
    );
  }
}
