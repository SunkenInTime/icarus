import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:custom_mouse_cursor/custom_mouse_cursor.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';

import 'package:windows_single_instance/windows_single_instance.dart';
import 'package:icarus/const/custom_icons.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/const/routes.dart';
import 'package:icarus/const/second_instance_args.dart';
import 'package:icarus/const/settings.dart' show Settings;
import 'package:icarus/const/app_storage.dart';
import 'package:icarus/hive/hive_registrar.g.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/in_app_debug_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/folder_navigator.dart';
import 'package:icarus/widgets/global_shortcuts.dart';
import 'package:icarus/widgets/settings_tab.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';
import 'package:window_manager/window_manager.dart';

import 'package:icarus/firebase_options.dart';

late CustomMouseCursor staticDrawingCursor;
WebViewEnvironment? webViewEnvironment;
bool isWebViewInitialized = false;
Future<void> main(List<String> args) async {
  if (args.isNotEmpty) {
    log("Path: ${args.first}");
  }

  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  if (!kIsWeb && Platform.isWindows) {
    await WindowsSingleInstance.ensureSingleInstance(
      args,
      'icarus_single_instance',
      onSecondWindow: (args) {
        publishSecondInstanceArgs(args);
      },
    );
  }

  if (kIsWeb) {
    // On web, Hive uses IndexedDB; no path needed.
    await Hive.initFlutter();
  } else {
    final hiveDir = await AppStorage.hiveRoot();
    final tempDir = await getTemporaryDirectory();
    log("Hive Directory (Hackathon): ${hiveDir.path}");
    log("Temporary Directory: ${tempDir.path}");
    await Hive.initFlutter(hiveDir.path);
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

  log("Web");
  // Ensure WebView2 environment is initialized on Windows before any InAppWebView
  // widgets are created. This is especially important in testing/dev where the
  // WebView user-data folder and runtime selection can affect behavior.
  // if (!kIsWeb && Platform.isWindows) {
  //   await _initWebViewEnvironment();
  // }

  runApp(ProviderScope(child: MyApp(data: args)));
}

Future<void> _initWebViewEnvironment() async {
  if (kIsWeb) return;
  if (Platform.isWindows) {
    final dir = await AppStorage.webViewRoot();
    final availableVersion = await WebViewEnvironment.getAvailableVersion();

    if (availableVersion == null) {
      isWebViewInitialized = false;
      return;
    }

    isWebViewInitialized = true;

    webViewEnvironment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: dir.path,
      ),
    );
  }
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key, required this.data});
  final List<String> data;

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> {
  StreamSubscription<List<String>>? _secondInstanceSub;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.data.isEmpty) return;
      log("Data: ${widget.data}");

      ref.read(inAppDebugProvider.notifier).bulkAddLogs(widget.data);
      ref.read(strategyProvider.notifier).loadFromFilePath(widget.data.first);
    });

    _secondInstanceSub = secondInstanceArgsController.stream.listen((args) {
      if (args.isEmpty) return;

      log("Second instance args: $args");
      log("Data: ${widget.data}");

      ref.read(strategyProvider.notifier).loadFromFilePath(args.first);
      ref.read(inAppDebugProvider.notifier).bulkAddLogs(args);
    });
  }

  @override
  void dispose() {
    _secondInstanceSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ToastificationWrapper(
      config: const ToastificationConfig(
        alignment: Alignment.bottomCenter,
        // itemWidth: 440,
        animationDuration: Duration(milliseconds: 500),
        blockBackgroundInteraction: false,
      ),
      child: ShadApp(
        navigatorKey: appNavigatorKey,
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
        builder: (context, child) {
          return GlobalShortcuts(child: child ?? const SizedBox.shrink());
        },
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
