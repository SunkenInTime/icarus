import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

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
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/routes.dart';
import 'package:icarus/const/second_instance_args.dart';
import 'package:icarus/const/settings.dart' show Settings;
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/replay_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/replay_view.dart';
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
bool isWebViewInitialized = false;
Future<void> main(List<String> args) async {
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      appProviderContainer = ProviderContainer();
      final startupReplayArgs = _parseStartupReplayArgs(args);
      final isReplayCaptureLaunch = startupReplayArgs != null;
      await _initializePersistedDebugLog(
        isReplayCaptureLaunch: isReplayCaptureLaunch,
      );
      _installGlobalErrorHandlers();

      if (!kIsWeb && Platform.isWindows) {
        await WindowsSingleInstance.ensureSingleInstance(
          args,
          isReplayCaptureLaunch
              ? 'icarus_single_instance_replay_capture'
              : 'icarus_single_instance',
          onSecondWindow: (args) {
            publishSecondInstanceArgs(args);
          },
        );
      }

      if (kIsWeb) {
        // On web, Hive uses IndexedDB; no path needed.
        await Hive.initFlutter();
      } else {
        // On mobile/desktop, you can still choose an explicit directory.
        final dir = await _applicationSupportDirectory(
          isReplayCaptureLaunch: isReplayCaptureLaunch,
        );
        await getTemporaryDirectory();
        await Hive.initFlutter(dir.path);
      }

      staticDrawingCursor = await CustomMouseCursor.icon(
        CustomIcons.drawcursor,
        size: 12,
        hotX: 6,
        hotY: 6,
        color: Colors.white,
      );

      registerIcarusAdapters(Hive);

      await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
      await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
      await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
      await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
      await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);

      await MapThemeProfilesProvider.bootstrap();

      await StrategyProvider.migrateAllStrategies();

      // await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).clear();

      await _initWebViewEnvironment(
        isReplayCaptureLaunch: isReplayCaptureLaunch,
      );

      if (!kIsWeb) {
        await windowManager.ensureInitialized();
        final windowOptions = WindowOptions(
          title: startupReplayArgs == null
              ? "Icarus: Valorant Strategies & Line ups ${Settings.versionName}"
              : "Icarus Replay Capture",
        );
        windowManager.waitUntilReadyToShow(windowOptions, () async {
          await windowManager.show();
          await windowManager.focus();
        });
      }

      // Ensure WebView2 environment is initialized on Windows before any InAppWebView
      // widgets are created. This is especially important in testing/dev where the
      // WebView user-data folder and runtime selection can affect behavior.
      // if (!kIsWeb && Platform.isWindows) {
      //   await _initWebViewEnvironment();
      // }

      runApp(
        UncontrolledProviderScope(
          container: appProviderContainer,
          child: MyApp(data: args),
        ),
      );
    },
    (error, stackTrace) {
      AppErrorReporter.reportError(
        'An unexpected application error occurred.',
        error: error,
        stackTrace: stackTrace,
        source: 'main.runZonedGuarded',
      );
    },
  );
}

void _installGlobalErrorHandlers() {
  final originalFlutterOnError = FlutterError.onError;

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    if (originalFlutterOnError != null &&
        !identical(originalFlutterOnError, FlutterError.presentError)) {
      originalFlutterOnError(details);
    }

    AppErrorReporter.reportError(
      'A UI error occurred.',
      error: details.exception,
      stackTrace: details.stack,
      source: 'FlutterError.onError',
    );
  };

  PlatformDispatcher.instance.onError = (error, stackTrace) {
    AppErrorReporter.reportError(
      'An unexpected asynchronous error occurred.',
      error: error,
      stackTrace: stackTrace,
      source: 'PlatformDispatcher.onError',
    );
    return true;
  };
}

Future<Directory> _applicationSupportDirectory({
  required bool isReplayCaptureLaunch,
}) async {
  if (!isReplayCaptureLaunch) return getApplicationSupportDirectory();

  final dir = Directory(path.join(
    Directory.systemTemp.path,
    'icarus_replay_capture_support',
  ));
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

Future<void> _initializePersistedDebugLog({
  required bool isReplayCaptureLaunch,
}) async {
  if (kIsWeb) return;

  try {
    final dir = await _applicationSupportDirectory(
      isReplayCaptureLaunch: isReplayCaptureLaunch,
    );
    AppErrorReporter.setApplicationSupportDirectoryPath(dir.path);
    await AppErrorReporter.initializePersistedLog(
      path.join(dir.path, 'icarus_debug.log'),
    );
    AppErrorReporter.reportInfo(
      'Persisted debug log file: ${path.join(dir.path, 'icarus_debug.log')}',
      source: 'main._initializePersistedDebugLog',
    );
  } catch (error, stackTrace) {
    developer.log(
      'Failed to configure persisted debug logging.',
      name: 'main._initializePersistedDebugLog',
      error: error,
      stackTrace: stackTrace,
      level: 900,
    );
  }
}

Future<void> _initWebViewEnvironment({
  required bool isReplayCaptureLaunch,
}) async {
  if (kIsWeb) return;
  if (Platform.isWindows) {
    final dir = await _applicationSupportDirectory(
      isReplayCaptureLaunch: isReplayCaptureLaunch,
    );
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

  Future<void> _loadReplayTrackPathWithWarning(
    String filePath, {
    bool autoplay = false,
    double? speed,
  }) async {
    try {
      final track = await loadReplayTrackFromFile(filePath);
      final notifier = ref.read(replayProvider.notifier);
      notifier.setTrack(track, sourcePath: filePath);
      if (speed != null) {
        notifier.setPlaybackSpeed(speed);
      }
      if (autoplay) {
        notifier.togglePlayback();
      }
      appNavigatorKey.currentState?.pushNamed(Routes.replayView);
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        'Failed to load replay track from startup argument.',
        error: error,
        stackTrace: stackTrace,
        source: 'MyApp._loadReplayTrackPathWithWarning',
      );
    }
  }

  Future<void> _loadFromFilePathWithWarning(String filePath) async {
    try {
      await ref.read(strategyProvider.notifier).loadFromFilePath(filePath);
    } on NewerVersionImportException catch (error, stackTrace) {
      AppErrorReporter.reportError(
        NewerVersionImportException.userMessage,
        error: error,
        stackTrace: stackTrace,
        source: 'MyApp._loadFromFilePathWithWarning',
      );
    }
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.data.isEmpty) return;

      for (final argument in widget.data) {
        AppErrorReporter.reportInfo(
          'Startup argument: $argument',
          source: 'main.startupArgs',
        );
      }

      final startupReplay = _parseStartupReplayArgs(widget.data);
      if (startupReplay != null) {
        _loadReplayTrackPathWithWarning(
          startupReplay.path,
          autoplay: startupReplay.autoplay,
          speed: startupReplay.speed,
        );
        return;
      }

      _loadFromFilePathWithWarning(widget.data.first);
    });

    _secondInstanceSub = secondInstanceArgsController.stream.listen((args) {
      if (args.isEmpty) return;

      _loadFromFilePathWithWarning(args.first);
      for (final argument in args) {
        AppErrorReporter.reportInfo(
          'Second-instance argument: $argument',
          source: 'main.secondInstanceArgs',
        );
      }
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
          Routes.replayView: (context) => const ReplayView(),
          Routes.settings: (context) => const SettingsTab(),
        },
        builder: (context, child) {
          return GlobalShortcuts(child: child ?? const SizedBox.shrink());
        },
      ),
    );
  }
}

class _StartupReplayArgs {
  const _StartupReplayArgs({
    required this.path,
    required this.autoplay,
    required this.speed,
  });

  final String path;
  final bool autoplay;
  final double? speed;
}

_StartupReplayArgs? _parseStartupReplayArgs(List<String> args) {
  String? path;
  var autoplay = false;
  double? speed;

  for (var index = 0; index < args.length; index += 1) {
    final arg = args[index];
    if (arg == '--replay-track' && index + 1 < args.length) {
      path = args[++index];
    } else if (arg == '--replay-autoplay') {
      autoplay = true;
    } else if (arg == '--replay-speed' && index + 1 < args.length) {
      speed = double.tryParse(args[++index]);
    }
  }

  if (path == null) return null;
  return _StartupReplayArgs(path: path, autoplay: autoplay, speed: speed);
}

class MyHomePage extends ConsumerWidget {
  const MyHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const FolderNavigator();
  }
}
