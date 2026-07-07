import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_portal/flutter_portal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/screenshot/screenshot_view.dart';
import 'package:icarus/widgets/settings_tab.dart';
import 'package:icarus/widgets/cloud_sync_status_chip.dart';
import 'package:icarus/widgets/strategy_save_icon_button.dart';
import 'package:screenshot/screenshot.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class SaveAndLoadButton extends ConsumerStatefulWidget {
  const SaveAndLoadButton({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _SaveAndLoadButtonState();
}

class _SaveAndLoadButtonState extends ConsumerState<SaveAndLoadButton> {
  bool _isLoading = false;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Row(
        children: [
          ShadTooltip(
            builder: (context) => const Text("Settings"),
            child: ShadIconButton.ghost(
              foregroundColor: Colors.white,
              onPressed: () async {
                showShadDialog(
                  context: context,
                  builder: (context) => const SettingsTab(),
                );
              },
              icon: const Icon(Icons.settings),
            ),
          ),
          const AutoSaveButton(),
          const CloudSyncStatusChip(),
          ShadTooltip(
            builder: (context) => const Text("Export"),
            child: ShadIconButton.ghost(
              foregroundColor: Colors.white,
              onPressed: () async {
                if (kIsWeb) {
                  Settings.showToast(
                    message:
                        'This feature is only supported in the Windows version.',
                    backgroundColor: Settings.tacticalVioletTheme.destructive,
                  );
                  return;
                }

                await StrategyImportExportService(ref)
                    .exportFile(ref.read(strategyProvider).strategyId!);
              },
              icon: const Icon(Icons.file_upload),
            ),
          ),
          ShadTooltip(
            builder: (context) => const Text("Screenshot"),
            child: ShadIconButton.ghost(
              foregroundColor: Colors.white,
              onPressed: () async {
                if (kIsWeb) {
                  Settings.showToast(
                    message:
                        'This feature is only supported in the Windows version.',
                    backgroundColor: Settings.tacticalVioletTheme.destructive,
                  );
                  return;
                }
                if (_isLoading) return;
                setState(() {
                  _isLoading = true;
                });
                CoordinateSystem.instance.setIsScreenshot(true);

                final String id = ref.read(strategyProvider).strategyId!;

                await ref.read(strategyProvider.notifier).forceSaveNow(id);

                final newStrat =
                    Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
                        .values
                        .where((StrategyData strategy) {
                  return strategy.id == id;
                }).firstOrNull;

                if (newStrat == null) {
                  return;
                }
                final newController = ScreenshotController();
                final mapState = ref.read(mapProvider);
                final currentPageID =
                    ref.read(strategyPageSessionProvider).activePageId;

                if (currentPageID == null) return;

                final activePage = newStrat.pages.firstWhere(
                  (p) => p.id == currentPageID,
                  orElse: () => newStrat.pages.first,
                );

                try {
                  final image = await newController.captureFromWidget(
                    targetSize: CoordinateSystem.screenShotSize,
                    ProviderScope(
                      child: MediaQuery(
                        data: const MediaQueryData(
                            size: CoordinateSystem.screenShotSize),
                        child: ShadApp.custom(
                          themeMode: ThemeMode.dark,
                          darkTheme: ShadThemeData(
                            brightness: Brightness.dark,
                            colorScheme: Settings.tacticalVioletTheme,
                            breadcrumbTheme:
                                const ShadBreadcrumbTheme(separatorSize: 18),
                          ),
                          appBuilder: (context) {
                            return MaterialApp(
                              theme: Theme.of(context),
                              debugShowCheckedModeBanner: false,
                              home: ScreenshotView(
                                isAttack: activePage.isAttack,
                                mapValue: newStrat.mapData,
                                showSpawnBarrier: mapState.showSpawnBarrier,
                                showRegionNames: mapState.showRegionNames,
                                showUltOrbs: mapState.showUltOrbs,
                                agents: activePage.agentData,
                                abilities: activePage.abilityData,
                                text: activePage.textData,
                                images: activePage.imageData,
                                drawings: activePage.drawingData,
                                utilities: activePage.utilityData,
                                strategySettings: activePage.settings,
                                strategyState: ref.read(strategyProvider),
                                pageName: activePage.name,
                                lineUpGroups: activePage.lineUpGroups,
                                themeProfileId: newStrat.themeProfileId,
                                themeOverridePalette:
                                    newStrat.themeOverridePalette,
                              ),
                              builder: (context, child) {
                                return Portal(
                                    child: ShadAppBuilder(child: child!));
                              },
                            );
                          },
                        ),
                      ),
                    ),
                  );
                  setState(() {
                    _isLoading = false;
                  });
                  String? outputFile = await FilePicker.platform.saveFile(
                    type: FileType.custom,
                    dialogTitle: 'Please select an output file:',
                    fileName:
                        "${ref.read(strategyProvider).strategyName ?? "new image"}.png",
                    allowedExtensions: ['png'],
                  );
                  if (outputFile != null) {
                    final file = File(outputFile);
                    await file.writeAsBytes(image);
                  }
                } catch (_) {
                } finally {
                  ref.read(screenshotProvider.notifier).setIsScreenShot(false);
                  CoordinateSystem.instance.setIsScreenshot(false);
                  ref
                      .read(drawingProvider.notifier)
                      .rebuildAllPaths(CoordinateSystem.instance);
                }
                // CoordinateSystem.instance.setIsScreenshot(false);
              },
              icon: _isLoading
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.camera_alt_outlined),
            ),
          ),
          if (_isViewOnly()) ...[
            const SizedBox(width: 4),
            const _ViewOnlyChip(),
          ],
        ],
      ),
    );
  }

  bool _isViewOnly() {
    final source = ref.watch(strategyProvider.select((value) => value.source));
    if (source != StrategySource.cloud ||
        !ref.watch(isCloudCollabEnabledProvider)) {
      return false;
    }
    // Read the cached role rather than the raw snapshot so the chip does not
    // flicker off while the snapshot is reloading or transiently errored; it
    // is absent only before the role has ever been known.
    final role = ref.watch(lastKnownCloudRoleProvider);
    return role == 'viewer';
  }
}

/// Non-interactive chip shown in the editor top strip when the open cloud
/// strategy is shared with view-only access.
class _ViewOnlyChip extends StatelessWidget {
  const _ViewOnlyChip();

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;

    return ShadTooltip(
      builder: (context) => const Text(
        'You have view access. Ask the owner for edit access to make changes.',
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: theme.muted,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.visibility_outlined,
              size: 14,
              color: theme.mutedForeground,
            ),
            const SizedBox(width: 6),
            Text(
              'View only',
              style: TextStyle(
                color: theme.mutedForeground,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
