import 'dart:developer';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_portal/flutter_portal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/active_page_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/screenshot/screenshot_view.dart';
import 'package:icarus/widgets/ai_chat_sheet.dart';
import 'package:icarus/widgets/settings_tab.dart';
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
                showShadSheet(
                  side: ShadSheetSide.left,
                  context: context,
                  builder: (context) => const SettingsTab(),
                );
              },
              icon: const Icon(Icons.settings),
            ),
          ),
          ShadTooltip(
            builder: (context) => const Text("AI Chat"),
            child: ShadIconButton.ghost(
              foregroundColor: Colors.white,
              onPressed: () async {
                showShadSheet(
                  side: ShadSheetSide.right,
                  context: context,
                  builder: (context) => const AiChatSheet(),
                );
              },
              icon: const Icon(Icons.auto_awesome),
            ),
          ),
          const AutoSaveButton(),
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

                await ref
                    .read(strategyProvider.notifier)
                    .exportFile(ref.read(strategyProvider).id);
              },
              icon: const Icon(Icons.file_upload),
            ),
          ),
          ShadIconButton.ghost(
            icon: const Icon(Icons.developer_board),
            foregroundColor: Colors.white,
            onPressed: () async {
              const pad = EdgeInsets.fromLTRB(10, 33, 37, 35);
              final px = CoordinateSystem.valorantPaddedPercentToContainerPx(
                u: 0.3315,
                v: 0.2615,
                referencePaddingInViewBoxUnits: pad,
                containerSize: CoordinateSystem.instance.playAreaSize,
                viewBoxSize: const Size(452, 474),
              );
              // final px = CoordinateSystem.valorantPercentToContainerPx(
              //   u: 0.3315,
              //   v: 0.2615,
              //   containerSize: CoordinateSystem.instance.playAreaSize,
              //   viewBoxSize: const Size(452, 474),
              // );

              final norm = CoordinateSystem.instance.screenToCoordinate(px);

              final agent = PlacedAgent(
                id: "1",
                type: AgentType.jett,
                position: norm,
              );
              ref.read(agentProvider.notifier).addAgent(agent);
            },
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

                final String id = ref.read(strategyProvider).id;

                await ref.read(strategyProvider.notifier).forceSaveNow(id);

                final newStrat =
                    Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
                        .values
                        .where((StrategyData strategy) {
                  return strategy.id == id;
                }).firstOrNull;

                if (newStrat == null) {
                  log("Couldn't find save");
                  return;
                }
                final newController = ScreenshotController();
                final currentPageID = ref.read(activePageProvider);

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
                                agents: activePage.agentData,
                                abilities: activePage.abilityData,
                                text: activePage.textData,
                                images: activePage.imageData,
                                drawings: activePage.drawingData,
                                utilities: activePage.utilityData,
                                strategySettings: activePage.settings,
                                strategyState: ref.read(strategyProvider),
                                lineUps: activePage.lineUps,
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
                        "${ref.read(strategyProvider).stratName ?? "new image"}.png",
                    allowedExtensions: ['png'],
                  );
                  if (outputFile != null) {
                    final file = File(outputFile);
                    await file.writeAsBytes(image);
                  }
                } catch (e, st) {
                  log('$e\n$st');
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
        ],
      ),
    );
  }
}
