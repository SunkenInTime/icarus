import 'dart:developer';
import 'dart:io';

import 'package:custom_mouse_cursor/custom_mouse_cursor.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/custom_icons.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/routes.dart';
import 'package:icarus/const/settings.dart' show Settings;
import 'package:icarus/hive/hive_registrar.g.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/folder_navigator.dart';
import 'package:icarus/widgets/global_shortcuts.dart';
import 'package:icarus/widgets/settings_tab.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';
import 'package:window_manager/window_manager.dart';

late CustomMouseCursor staticDrawingCursor;
WebViewEnvironment? webViewEnvironment;
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

  staticDrawingCursor = await CustomMouseCursor.icon(
    CustomIcons.drawcursor,
    size: 12,
    hotX: 6,
    hotY: 6,
    color: Colors.white,
  );

  Hive.registerAdapters();

  await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
  await Hive.openBox<Folder>(HiveBoxNames.foldersBox);

  await StrategyProvider.migrateAllStrategies();
  // await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).clear();

  await _initWebViewEnvironment();
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

  // Ensure WebView2 environment is initialized on Windows before any InAppWebView
  // widgets are created. This is especially important in testing/dev where the
  // WebView user-data folder and runtime selection can affect behavior.
  if (!kIsWeb && Platform.isWindows) {
    await _initWebViewEnvironment();
  }

  runApp(const ProviderScope(child: MyApp()));
}

Future<void> _initWebViewEnvironment() async {
  final dir = await getApplicationSupportDirectory();
  if (Platform.isWindows) {
    final availableVersion = await WebViewEnvironment.getAvailableVersion();
    if (availableVersion == null) {
      throw Exception("No available version found"); // TODO: Will replace this
    }
    webViewEnvironment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: path.join(dir.path, 'webview'),
      ),
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GlobalShortcuts(
      child: ToastificationWrapper(
        config: const ToastificationConfig(
          alignment: Alignment.bottomCenter,
          // itemWidth: 440,
          animationDuration: Duration(milliseconds: 500),
          blockBackgroundInteraction: false,
        ),
        child: ShadApp(
          themeMode: ThemeMode.dark,
          darkTheme: ShadThemeData(
            brightness: Brightness.dark,
            colorScheme: Settings.tacticalVioletTheme,
            breadcrumbTheme: const ShadBreadcrumbTheme(separatorSize: 18),
          ),
          home: const MyHomePage(),
          routes: {
            Routes.folderNavigator: (context) => const FolderNavigator(),
            Routes.strategyView: (context) => const StrategyView(),
            Routes.settings: (context) => const SettingsTab(),
          },
        ),
      ),
    );
  }
}

class MyHomePage extends ConsumerWidget {
  const MyHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const FolderNavigator();
  }
}
