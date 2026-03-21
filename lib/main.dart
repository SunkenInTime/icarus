import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:app_links/app_links.dart';
import 'package:convex_flutter/convex_flutter.dart';
import 'package:custom_mouse_cursor/custom_mouse_cursor.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/services/deep_link_registrar.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:windows_single_instance/windows_single_instance.dart';
import 'package:icarus/const/custom_icons.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/routes.dart';
import 'package:icarus/const/second_instance_args.dart';
import 'package:icarus/const/settings.dart' show Settings;
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/in_app_debug_provider.dart';
import 'package:icarus/providers/map_theme_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
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
final AppLinks _appLinks = AppLinks();
final StreamController<Uri> _deepLinkUriController =
    StreamController<Uri>.broadcast();
StreamSubscription<Uri>? _deepLinkStreamSub;

Future<void> _initializeDeepLinkHandling() async {
  try {
    final initialLink = await _appLinks.getInitialLink();
    if (initialLink != null) {
      _publishDeepLink(initialLink, source: 'initial');
    }
  } catch (error, stackTrace) {
    developer.log(
      'Failed to read initial deep link: $error',
      name: 'deep_link',
      error: error,
      stackTrace: stackTrace,
    );
  }

  _deepLinkStreamSub ??= _appLinks.uriLinkStream.listen(
    (uri) => _publishDeepLink(uri, source: 'stream'),
    onError: (Object error, StackTrace stackTrace) {
      developer.log(
        'Deep link stream error: $error',
        name: 'deep_link',
        error: error,
        stackTrace: stackTrace,
      );
    },
  );
}

void _publishDeepLink(Uri uri, {required String source}) {
  developer.log('Deep link received [$source]: $uri', name: 'deep_link');
  _deepLinkUriController.add(uri);
}

Future<void> main(List<String> args) async {
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      appProviderContainer = ProviderContainer();
      await _initializePersistedDebugLog();
      _installGlobalErrorHandlers();

      await registerDeepLinkProtocol('icarus');
      await _initializeDeepLinkHandling();

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
        // On mobile/desktop, you can still choose an explicit directory.
        final dir = await getApplicationSupportDirectory();
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

      await ConvexClient.initialize(
        const ConvexConfig(
          deploymentUrl: 'https://majestic-eel-413.convex.cloud',
          clientId: 'dev:majestic-eel-413',
          operationTimeout: Duration(seconds: 30),
          healthCheckQuery: 'health:ping',
        ),
      );

      await Supabase.initialize(
        url: 'https://gjdirtrtgnawqoruavqn.supabase.co',
        anonKey: 'sb_publishable_6M0VCSZCvRFrcgNANWPVWw_U06T_rUo',
        authOptions: const FlutterAuthClientOptions(detectSessionInUri: false),
      );

      // await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).clear();

      await _initWebViewEnvironment();

      if (!kIsWeb) {
        await windowManager.ensureInitialized();
        WindowOptions windowOptions = const WindowOptions(
          title:
              "Icarus: Valorant Strategies & Line ups ${Settings.versionName}",
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

Future<void> _initializePersistedDebugLog() async {
  if (kIsWeb) return;

  try {
    final dir = await getApplicationSupportDirectory();
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
  StreamSubscription<Uri>? _deepLinkSub;
  final Set<String> _processedDeepLinks = <String>{};

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

  Future<void> _handleIncomingArgument(
    String argument, {
    required String source,
  }) async {
    final uri = Uri.tryParse(argument);
    if (uri != null && uri.scheme.toLowerCase() == 'icarus') {
      _handleIncomingUri(uri, source: source);
      return;
    }

    await _loadFromFilePathWithWarning(argument);
  }

  void _handleIncomingUri(Uri uri, {required String source}) {
    final uriText = uri.toString();
    if (!_processedDeepLinks.add(uriText)) {
      developer.log(
        'Ignoring duplicate deep link [$source]: $uriText',
        name: 'deep_link',
      );
      return;
    }

    developer.log('Handling deep link [$source]: $uriText', name: 'deep_link');
    ref
        .read(inAppDebugProvider.notifier)
        .bulkAddLogs(<String>['Deep link [$source]: $uriText']);

    unawaited(
      ref
          .read(authProvider.notifier)
          .handleAuthCallbackUri(uri, source: source),
    );
  }

  @override
  void initState() {
    super.initState();
    ref.read(authProvider);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.data.isEmpty) return;

      for (final argument in widget.data) {
        AppErrorReporter.reportInfo(
          'Startup argument: $argument',
          source: 'main.startupArgs',
        );
        unawaited(_handleIncomingArgument(argument, source: 'startup_args'));
      }
    });

    _secondInstanceSub = secondInstanceArgsController.stream.listen((args) {
      if (args.isEmpty) return;

      for (final argument in args) {
        AppErrorReporter.reportInfo(
          'Second-instance argument: $argument',
          source: 'main.secondInstanceArgs',
        );
        unawaited(_handleIncomingArgument(argument, source: 'second_instance'));
      }
    });

    _deepLinkSub = _deepLinkUriController.stream.listen(
      (uri) => _handleIncomingUri(uri, source: 'app_links'),
    );
  }

  @override
  void dispose() {
    _secondInstanceSub?.cancel();
    _deepLinkSub?.cancel();
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
