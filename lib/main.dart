import 'dart:developer';

import 'package:custom_mouse_cursor/custom_mouse_cursor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/custom_icons.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/routes.dart';
import 'package:icarus/const/settings.dart' show Settings;
import 'package:icarus/hive/hive_registrar.g.dart';
import 'package:icarus/home_view.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/folder_navigator.dart';
import 'package:icarus/widgets/global_shortcuts.dart';
import 'package:icarus/widgets/settings_tab.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

CustomMouseCursor? drawingCursor;
CustomMouseCursor? erasingCursor;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final directory = await getApplicationSupportDirectory();
  log("App Support Directory: ${directory.path}");
  await Hive.initFlutter(directory.path);

  Hive.registerAdapters();

  await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
  await Hive.openBox<Folder>(HiveBoxNames.foldersBox);

  // await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).clear();
  await windowManager.ensureInitialized();
  WindowOptions windowOptions = const WindowOptions(
    title: "Icarus: Valorant Strategies & Line ups 1.7.5",
  );

  drawingCursor = await CustomMouseCursor.icon(
    CustomIcons.drawcursor,
    size: 12, hotX: 6, hotY: 6, color: Colors.white,
    // hotX: 22,
    // hotY: 17,
    // color: Colors.pinkAccent,
  );

  erasingCursor = await CustomMouseCursor.icon(
    CustomIcons.eraser,
    size: 12, hotX: 6, hotY: 6, color: Colors.white,
    // hotX: 22,
    // hotY: 17,
    // color: Colors.pinkAccent,
  );

  // drawingCursor = await CustomMouseCursor.asset(
  //   "assets/drawCursor.webp",
  //   hotX: 12,
  //   hotY: 4,
  // );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GlobalShortcuts(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Icarus',
        theme: Settings.appTheme,
        routes: {
          Routes.folderNavigator: (context) => const FolderNavigator(),
          Routes.strategyView: (context) => const StrategyView(),
          Routes.settings: (context) => const SettingsTab(),
        },
        home: const MyHomePage(),
      ),
    );
  }
}

class MyHomePage extends ConsumerWidget {
  const MyHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const HomeView();
  }
}
