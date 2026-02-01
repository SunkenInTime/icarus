import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_portal/flutter_portal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/active_page_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/screenshot/screenshot_view.dart';
import 'package:screenshot/screenshot.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

Future<Uint8List> captureCleanMapScreenshot(WidgetRef ref) async {
  if (kIsWeb) {
    throw UnsupportedError('Screenshot capture is not supported on web.');
  }

  final id = ref.read(strategyProvider).id;

  // Ensure any in-memory edits are flushed to Hive so the screenshot is current.
  await ref.read(strategyProvider.notifier).forceSaveNow(id);

  final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
  StrategyData? strat = box.get(id);
  if (strat == null) {
    for (final s in box.values) {
      if (s.id == id) {
        strat = s;
        break;
      }
    }
  }
  if (strat == null) {
    throw StateError("Couldn't load strategy for screenshot");
  }

  final stratData = strat;

  final currentPageId = ref.read(activePageProvider);
  if (currentPageId == null) {
    throw StateError("No active page selected");
  }

  final activePage = stratData.pages.firstWhere(
    (p) => p.id == currentPageId,
    orElse: () => stratData.pages.first,
  );

  final controller = ScreenshotController();

  CoordinateSystem.instance.setIsScreenshot(true);
  try {
    final bytes = await controller.captureFromWidget(
      targetSize: CoordinateSystem.screenShotSize,
      ProviderScope(
        child: MediaQuery(
          data: const MediaQueryData(size: CoordinateSystem.screenShotSize),
          child: ShadApp.custom(
            themeMode: ThemeMode.dark,
            darkTheme: ShadThemeData(
              brightness: Brightness.dark,
              colorScheme: Settings.tacticalVioletTheme,
              breadcrumbTheme: const ShadBreadcrumbTheme(separatorSize: 18),
            ),
            appBuilder: (context) {
              return MaterialApp(
                theme: Theme.of(context),
                debugShowCheckedModeBanner: false,
                home: ScreenshotView(
                  isAttack: activePage.isAttack,
                  mapValue: stratData.mapData,
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
                  return Portal(child: ShadAppBuilder(child: child!));
                },
              );
            },
          ),
        ),
      ),
    );
    return bytes;
  } finally {
    ref.read(screenshotProvider.notifier).setIsScreenShot(false);
    CoordinateSystem.instance.setIsScreenshot(false);
    ref
        .read(drawingProvider.notifier)
        .rebuildAllPaths(CoordinateSystem.instance);
  }
}
