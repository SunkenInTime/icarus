import 'dart:async';

import 'package:desktop_updater/desktop_updater.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/update_checker.dart';
import 'package:icarus/main.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_navigation_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/providers/update_status_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/services/windows_desktop_update_controller.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/desktop_update_dialog.dart';
import 'package:icarus/widgets/dialogs/strategy/create_strategy_dialog.dart';
import 'package:icarus/widgets/dialogs/web_view_dialog.dart';
import 'package:icarus/widgets/folder_content.dart';
import 'package:icarus/widgets/library_title_strip.dart';
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
  final ShadContextMenuController _backgroundMenuController =
      ShadContextMenuController();

  bool get _isWindowsDesktop =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  @override
  void dispose() {
    _backgroundMenuController.dispose();
    _desktopUpdaterController?.dispose();
    super.dispose();
  }

  static const _desktopUpdateLocalization = DesktopUpdateLocalization(
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
  );

  @override
  void initState() {
    super.initState();

    if (kDebugMode && kDebugForceDesktopUpdateDialog) {
      _desktopUpdaterController = WindowsDesktopUpdateController.debugPreview(
        localization: _desktopUpdateLocalization,
      );
    }

    // Show the demo warning only once after the first frame on web.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _followCloudAvailability(ref.read(isCloudWorkspaceAvailableProvider));
      if (!_warnedOnce) {
        _warnedOnce = true;

        _warnWebView();
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

  void _showDesktopOnlyToast() {
    Settings.showToast(
      message: 'This feature is only supported in the Windows version.',
      backgroundColor: Settings.tacticalVioletTheme.destructive,
    );
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

  /// Signed in, My Library writes to the cloud. Auth restores after the
  /// first frame, so re-land on the tab's root once the cloud is reachable.
  void _followCloudAvailability(bool available) {
    if (!available) return;
    if (ref.read(libraryTabProvider) != LibraryTab.library) return;
    if (ref.read(libraryWorkspaceProvider) == LibraryWorkspace.cloud) return;
    if (ref.read(folderProvider) != null) return;
    ref.read(libraryNavigationProvider).showLibrary();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(
      isCloudWorkspaceAvailableProvider,
      (_, available) => _followCloudAvailability(available),
    );
    ref.listen<AsyncValue<UpdateCheckResult>>(appUpdateStatusProvider,
        (_, next) {
      next.whenData((result) {
        if (!mounted) {
          return;
        }

        final bool isDirectWindowsInstall =
            _isWindowsDesktop && !result.isSupported;
        if (isDirectWindowsInstall && _desktopUpdaterController == null) {
          debugPrint(
            'Desktop updater channel: $kResolvedUpdateChannel | Manifest: ${Settings.desktopUpdaterArchiveUrl}',
          );
          _desktopUpdaterController = WindowsDesktopUpdateController(
            appArchiveUrl: Settings.desktopUpdaterArchiveUrl,
            localization: _desktopUpdateLocalization,
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
    final tab = ref.watch(libraryTabProvider);
    final workspace = ref.watch(libraryWorkspaceProvider);
    final isCloudWorkspace = workspace == LibraryWorkspace.cloud;
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
    final canCreate = tab == LibraryTab.library;

    Future<void> navigateToLocalStrategy(
      BuildContext context,
      String strategyId, {
      String? strategyName,
    }) async {
      if (!context.mounted) return;
      await Navigator.push(
        context,
        StrategyView.route(
          initialStrategyId: strategyId,
          initialStrategyName: strategyName,
          initialStrategySource: StrategySource.local,
          initialMapValue: MapValue.ascent,
          initialIsAttack: true,
        ),
      );
    }

    Future<void> showCreateFolderDialog() async {
      await showDialog<String>(
        context: context,
        builder: (context) {
          return const FolderEditDialog();
        },
      );
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
        if (ref.read(libraryWorkspaceProvider) == LibraryWorkspace.cloud) {
          await Navigator.push(
            context,
            StrategyView.route(),
          );
        } else {
          await navigateToLocalStrategy(context, strategyId);
        }
      }
    }

    return Stack(
      children: [
        Scaffold(
          body: Column(
            children: [
              LibraryTitleStrip(
                onCreateStrategy: showCreateDialog,
                onCreateFolder: showCreateFolderDialog,
                onImportIca: handleImportIca,
                onImportBackup: handleImportBackup,
                onExportLibrary: handleExportLibrary,
              ),
              Expanded(
                child: ShadContextMenuRegion(
                  controller: _backgroundMenuController,
                  items: !canCreate
                      ? const []
                      : [
                          ShadContextMenuItem(
                            leading:
                                const Icon(Icons.create_new_folder_outlined),
                            onPressed: showCreateFolderDialog,
                            child: const Text('Create Folder'),
                          ),
                          ShadContextMenuItem(
                            leading: const Icon(Icons.note_add_outlined),
                            onPressed: showCreateDialog,
                            child: const Text('Create Strategy'),
                          ),
                        ],
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeOutCubic,
                    child: KeyedSubtree(
                      key: ValueKey(tab),
                      child: FolderContent(
                        folder: currentFolder,
                        onCreateStrategy: showCreateDialog,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_desktopUpdaterController != null)
          DesktopUpdateDialogListener(
            controller: _desktopUpdaterController!,
          ),
      ],
    );
  }
}

/// Something the user can drag around the library grid.
sealed class GridItem {
  /// The store the item lives in. Drops across stores are refused.
  LibraryWorkspace get store;
}

class FolderItem extends GridItem {
  final Folder folder;
  @override
  final LibraryWorkspace store;

  FolderItem(this.folder, {required this.store});
}

class StrategyItem extends GridItem {
  final String strategyId;
  final StrategyData? strategy;

  StrategyItem.local(this.strategy) : strategyId = strategy!.id;

  StrategyItem.cloud(this.strategyId) : strategy = null;

  @override
  LibraryWorkspace get store =>
      strategy == null ? LibraryWorkspace.cloud : LibraryWorkspace.local;
}
