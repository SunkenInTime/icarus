import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:custom_mouse_cursor/custom_mouse_cursor.dart';
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
import 'package:icarus/hive/hive_registrar.g.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/in_app_debug_provider.dart';
import 'package:icarus/providers/map_theme_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/ui_theme_provider.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/theme/ui_theme_runtime.dart';
import 'package:icarus/widgets/folder_navigator.dart';
import 'package:icarus/widgets/global_shortcuts.dart';
import 'package:icarus/widgets/settings_tab.dart';
import 'package:icarus/widgets/theme_token_map_page.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';
import 'package:window_manager/window_manager.dart';

late CustomMouseCursor staticDrawingCursor;
WebViewEnvironment? webViewEnvironment;
bool isWebViewInitialized = false;
Future<void> main(List<String> args) async {
  if (args.isNotEmpty) {
    log("Path: ${args.first}");
  }

  WidgetsFlutterBinding.ensureInitialized();

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
    await Hive.initFlutter();
  } else {
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
  await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
  await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
  await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
  await Hive.openBox<String>(HiveBoxNames.uiThemeProfilesBox);
  await Hive.openBox<String>(HiveBoxNames.uiThemePrefsBox);

  await MapThemeProfilesProvider.bootstrap();
  await UiThemeProvider.bootstrap();

  await StrategyProvider.migrateAllStrategies();

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

  runApp(ProviderScope(child: MyApp(data: args)));
}

Future<void> _initWebViewEnvironment() async {
  if (kIsWeb) return;
  if (Platform.isWindows) {
    final dir = await getApplicationSupportDirectory();
    final availableVersion = await WebViewEnvironment.getAvailableVersion();

    if (availableVersion == null) {
      isWebViewInitialized = false;
      return;
    }

    isWebViewInitialized = true;

    webViewEnvironment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: path.join(dir.path, 'webview'),
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

  Future<void> _loadFromFilePathWithWarning(String filePath) async {
    try {
      await ref.read(strategyProvider.notifier).loadFromFilePath(filePath);
    } on NewerVersionImportException {
      if (!mounted) return;
      Settings.showToast(
        message: NewerVersionImportException.userMessage,
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
    }
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.data.isEmpty) return;
      log("Data: ${widget.data}");

      ref.read(inAppDebugProvider.notifier).bulkAddLogs(widget.data);
      _loadFromFilePathWithWarning(widget.data.first);
    });

    _secondInstanceSub = secondInstanceArgsController.stream.listen((args) {
      if (args.isEmpty) return;

      log("Second instance args: $args");
      log("Data: ${widget.data}");

      _loadFromFilePathWithWarning(args.first);
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
    final effectiveTheme = ref.watch(effectiveUiThemeProvider);
    UiThemeRuntime.apply(effectiveTheme);

    return ToastificationWrapper(
      config: const ToastificationConfig(
        alignment: Alignment.bottomCenter,
        animationDuration: Duration(milliseconds: 500),
        blockBackgroundInteraction: false,
      ),
      child: ShadApp(
        navigatorKey: appNavigatorKey,
        themeMode: ThemeMode.dark,
        darkTheme: ShadThemeData(
          brightness: Brightness.dark,
          colorScheme: effectiveTheme.shadColorScheme,
          breadcrumbTheme: const ShadBreadcrumbTheme(separatorSize: 18),
        ),
        home: const MyHomePage(),
        routes: {
          Routes.folderNavigator: (context) => const FolderNavigator(),
          Routes.strategyView: (context) => const StrategyView(),
          Routes.settings: (context) => const SettingsTab(),
          Routes.themeTokenMap: (context) => const ThemeTokenMapPage(),
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
