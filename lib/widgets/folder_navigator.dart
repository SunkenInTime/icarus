import 'dart:developer';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/update_checker.dart';
import 'package:icarus/main.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/current_path_bar.dart';
import 'package:icarus/widgets/custom_button.dart';
import 'package:icarus/widgets/custom_search_field.dart';
import 'package:icarus/widgets/demo_dialog.dart';
import 'package:icarus/widgets/demo_tag.dart';
import 'package:icarus/widgets/dialogs/strategy/create_strategy_dialog.dart';
import 'package:icarus/widgets/dialogs/web_view_dialog.dart';
import 'package:icarus/widgets/folder_content.dart';
import 'package:icarus/widgets/folder_edit_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class FolderNavigator extends ConsumerStatefulWidget {
  const FolderNavigator({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _FolderNavigatorState();
}

class _FolderNavigatorState extends ConsumerState<FolderNavigator> {
  bool _warnedOnce = false;
  void _checkUpdate() async {
    await UpdateChecker.checkForUpdate(context);
  }

  @override
  void initState() {
    super.initState();
    _checkUpdate();

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

  @override
  Widget build(BuildContext context) {
    final double height = MediaQuery.sizeOf(context).height - 90;
    final Size playAreaSize = Size(height * 1.2, height);
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
                onPressed: () async {
                  if (kIsWeb) {
                    Settings.showToast(
                      message:
                          'This feature is only supported in the Windows version.',
                      backgroundColor: Settings.tacticalVioletTheme.destructive,
                    );
                    return;
                  }
                  await ref
                      .read(strategyProvider.notifier)
                      .loadFromFilePicker();
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
                child: const Text('Sigma Button'),
              ),
              // CustomButton(
              //   onPressed: showCreateDialog,
              //   height: 40,
              //   icon: const Icon(Icons.add, color: Colors.white),
              //   label: "Create Strategy",
              //   labelColor: Colors.white,
              //   backgroundColor: Colors.deepPurple,
              // ),
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
