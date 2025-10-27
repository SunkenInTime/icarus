import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/screenshot/screenshot_view.dart';
import 'package:icarus/widgets/settings_tab.dart';
import 'package:icarus/widgets/strategy_save_icon_button.dart';
import 'package:screenshot/screenshot.dart';

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
          IconButton(
            onPressed: () async {
              // // Navigator.of(context).pushNamed(Routes.settings);
              // Navigator.of(context).push(
              //   PageRouteBuilder(
              //     opaque: false,
              //     // barrierColor: Colors.black54,
              //     pageBuilder: (_, __, ___) => const SettingsTab(),
              //   ),
              // );

              Navigator.of(context).push(
                PageRouteBuilder(
                  opaque: false,
                  transitionDuration: const Duration(milliseconds: 250),
                  reverseTransitionDuration: const Duration(milliseconds: 200),
                  pageBuilder: (context, animation, secondaryAnimation) {
                    return const SettingsTab();
                  },
                  transitionsBuilder:
                      (context, animation, secondaryAnimation, child) {
                    // Slide from right to left on push, and left to right on pop
                    final offsetAnimation = Tween<Offset>(
                      begin: const Offset(
                          -1, 0.0), // start off-screen to the right
                      end: Offset.zero, // end at normal position
                    ).animate(CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutCubic,
                      reverseCurve: Curves.easeOutCubic,
                    ));

                    return SlideTransition(
                      position: offsetAnimation,
                      child: child,
                    );
                  },
                ),
              );
            },
            icon: const Icon(Icons.settings),
          ),
          const AutoSaveButton(),
          IconButton(
            tooltip: "Export",
            onPressed: () async {
              await ref
                  .read(strategyProvider.notifier)
                  .exportFile(ref.read(strategyProvider).id);
            },
            icon: const Icon(Icons.file_upload),
          ),
          IconButton(
            tooltip: "Screenshot",
            onPressed: () async {
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
              newController
                  .captureFromWidget(
                targetSize: CoordinateSystem.screenShotSize,
                ProviderScope(
                  child: MediaQuery(
                    data: const MediaQueryData(
                        size: CoordinateSystem.screenShotSize),
                    child: MaterialApp(
                      theme: Settings.appTheme,
                      debugShowCheckedModeBanner: false,
                      home: ScreenshotView(
                          isAttack: newStrat.isAttack,
                          mapValue: newStrat.mapData,
                          agents: newStrat.agentData,
                          abilities: newStrat.abilityData,
                          text: newStrat.textData,
                          images: newStrat.imageData,
                          drawings: newStrat.drawingData,
                          utilities: newStrat.utilityData,
                          strategySettings: newStrat.strategySettings,
                          strategyState: ref.read(strategyProvider)),
                    ),
                  ),
                ),
              )
                  .then((Uint8List? image) async {
                if (image == null) return;
                File file;
                // log("File name: ${state.fileName}");
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

                if (outputFile == null) return;

                file = File(outputFile);

                file.writeAsBytes(image);
                ref.read(screenshotProvider.notifier).setIsScreenShot(false);
              }).catchError((onError) {
                log(onError);
              });

              CoordinateSystem.instance.setIsScreenshot(false);
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
        ],
      ),
    );
  }
}
