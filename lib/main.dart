import 'dart:developer';

import 'package:custom_mouse_cursor/custom_mouse_cursor.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_portal/flutter_portal.dart';
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
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:window_manager/window_manager.dart';

CustomMouseCursor? drawingCursor;
CustomMouseCursor? erasingCursor;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    // On web, Hive uses IndexedDB; no path needed.
    await Hive.initFlutter();
  } else {
    // On mobile/desktop, you can still choose an explicit directory.
    final dir = await getApplicationSupportDirectory();
    final tempDir = await getTemporaryDirectory();
    log("App Support Directory: ${dir.path}");
    log("Temporary Directory: ${tempDir.path}");
    await Hive.initFlutter(dir.path);
  }

  Hive.registerAdapters();

  await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
  await Hive.openBox<Folder>(HiveBoxNames.foldersBox);

  await StrategyProvider.migrateAllStrategies();
  // await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).clear();

  drawingCursor = await CustomMouseCursor.icon(
    CustomIcons.drawcursor,

    size: 12, hotX: 6, hotY: 6, color: Colors.white,
    // hotX: 22,
    // hotY: 17,
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
  //

  if (!kIsWeb) {
    await windowManager.ensureInitialized();
    WindowOptions windowOptions = const WindowOptions(
      title: "Icarus: Valorant Strategies & Line ups ${Settings.versionName}",
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // return ShadApp.custom(
    //   themeMode: ThemeMode.dark,
    //   darkTheme: ShadThemeData(
    //     brightness: Brightness.dark,
    //     colorScheme: const ShadSlateColorScheme.dark(),
    //   ),
    //   appBuilder: (context) {
    //     return MaterialApp(
    //       theme: Theme.of(context),
    //       builder: (context, child) {
    //         return ShadAppBuilder(child: child!);
    //       },
    //     );
    //   },
    // );
    return GlobalShortcuts(
      child: Portal(
        child: ShadApp.custom(
            themeMode: ThemeMode.dark,
            darkTheme: ShadThemeData(
              brightness: Brightness.dark,
              colorScheme: const ShadVioletColorScheme.dark(),
            ),
            appBuilder: (context) {
              return MaterialApp(
                debugShowCheckedModeBanner: false,
                title: 'Icarus',
                // theme: Settings.appTheme,
                theme: Theme.of(context),
                home: const MyHomePage(),
                routes: {
                  Routes.folderNavigator: (context) => const FolderNavigator(),
                  Routes.strategyView: (context) => const StrategyView(),
                  Routes.settings: (context) => const SettingsTab(),
                },
                builder: (context, child) {
                  return ShadAppBuilder(child: child!);
                },
              );
            }),
      ),
    );

    // return GlobalShortcuts(
    //   child: Portal(
    //     child: MaterialApp(
    //       debugShowCheckedModeBanner: false,
    //       title: 'Icarus',
    //       theme: Settings.appTheme,
    //       // theme: Theme.of(context),
    //       home: const MyHomePage(),
    //       routes: {
    //         Routes.folderNavigator: (context) => const FolderNavigator(),
    //         Routes.strategyView: (context) => const StrategyView(),
    //         Routes.settings: (context) => const SettingsTab(),
    //       },
    //     ),
    //   ),
    // );
  }
}

class MyHomePage extends ConsumerWidget {
  const MyHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const FolderNavigator();
  }
}
