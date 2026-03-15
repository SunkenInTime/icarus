import 'dart:developer';
import 'dart:io';

import 'package:desktop_updater/desktop_updater.dart';
import 'package:desktop_updater/updater_controller.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/update_checker.dart';
import 'package:icarus/main.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/update_status_provider.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/current_path_bar.dart';
import 'package:icarus/widgets/desktop_update_dialog.dart';
import 'package:icarus/widgets/demo_dialog.dart';
import 'package:icarus/widgets/demo_tag.dart';
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
  DesktopUpdaterController? _desktopUpdaterController;
  final GlobalKey _importExportButtonKey = GlobalKey();
  final ShadPopoverController _importExportPopoverController =
      ShadPopoverController();

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
      await ref.read(strategyProvider.notifier).loadFromFilePicker();
    } on NewerVersionImportException {
      Settings.showToast(
        message: NewerVersionImportException.userMessage,
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
    }
  }

  Future<void> handleImportBackup() async {
    if (kIsWeb) {
      _showDesktopOnlyToast();
      return;
    }
    try {
      final result = await ref
          .read(strategyProvider.notifier)
          .importBackupFromFilePicker();
      if (result.hasImports || result.issues.isNotEmpty) {
        Settings.showToast(
          message: buildImportSummaryMessage(result),
          backgroundColor: result.hasImports
              ? Settings.tacticalVioletTheme.primary
              : Settings.tacticalVioletTheme.destructive,
        );
      }
    } catch (_) {
      Settings.showToast(
        message: 'Failed to import backup archive.',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
    }
  }

  Future<void> handleExportLibrary() async {
    if (kIsWeb) {
      _showDesktopOnlyToast();
      return;
    }
    await ref.read(strategyProvider.notifier).exportLibrary();
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
            !kIsWeb && Platform.isWindows && !result.isSupported;
        if (isDirectWindowsInstall && _desktopUpdaterController == null) {
          _desktopUpdaterController = DesktopUpdaterController(
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
    final currentFolderId = ref.watch(folderProvider);
    final currentFolder = currentFolderId != null
        ? ref.read(folderProvider.notifier).findFolderByID(currentFolderId)
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
        await navigateWithLoading(context, strategyId);
      }
    }

    return Stack(
      children: [
        Scaffold(
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
                      onPressed: _toggleImportExportPopover,
                      leading: const Icon(Icons.import_export),
                      trailing: const Icon(Icons.keyboard_arrow_down),
                      child: const Text('Import / Export'),
                    ),
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
  final StrategyData strategy;

  StrategyItem(this.strategy);
}
