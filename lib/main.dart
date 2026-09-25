import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ui' show PlatformDispatcher;

import 'package:app_links/app_links.dart';
import 'package:icarus/collab/convex_client.dart';
import 'package:icarus/collab/durable_cloud_media_outbox.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:custom_mouse_cursor/custom_mouse_cursor.dart';
import 'package:flutter/foundation.dart' show kIsWeb, kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/services/deep_link_registrar.dart';
import 'package:icarus/services/desktop_runtime.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:icarus/const/app_cursors.dart';
import 'package:icarus/const/custom_icons.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/routes.dart';
import 'package:icarus/const/second_instance_args.dart';
import 'package:icarus/const/settings.dart' show Settings;
import 'package:icarus/config/cloud_build_config.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/collab/cloud_media_cache_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/share/current_share_origin.dart';
import 'package:icarus/share/share_link_format.dart';
import 'package:icarus/services/auth_callback_uri.dart';
import 'package:icarus/services/browser_url.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/services/analytics_service.dart';
import 'package:icarus/services/cloud_sign_out_coordinator.dart';
import 'package:icarus/services/discord_presence_service.dart';
import 'package:icarus/services/guarded_sign_out.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus/startup/hive_store_launch.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/folder_navigator.dart';
import 'package:icarus/widgets/global_shortcuts.dart';
import 'package:icarus/widgets/mouse_navigation.dart';
import 'package:icarus/widgets/settings_tab.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

CustomMouseCursor? staticDrawingCursor;
WebViewEnvironment? webViewEnvironment;
bool isWebViewInitialized = false;
bool isWebViewWarmupComplete = false;
Future<void>? _webViewEnvironmentWarmupFuture;
final AppLinks _appLinks = AppLinks();
final StreamController<Uri> _deepLinkUriController =
    StreamController<Uri>.broadcast();
StreamSubscription<Uri>? _deepLinkStreamSub;
final List<Uri> _bufferedDeepLinks = <Uri>[];
bool _hasDeepLinkListener = false;

Future<void> _initializeDeepLinkHandling() async {
  if (kIsWeb) {
    // A browser has no OS deep links: the page's own URL is the only link
    // (app_links' web plugin just echoes it). It matters when it is Supabase
    // returning from Discord sign-in, or a /share/<code> link.
    final pageUri = Uri.base;
    final authCallback = classifyAuthCallbackUri(
      pageUri,
      redirectUri: currentAuthRedirectUri(),
    );
    if (authCallback != AuthCallback.none ||
        isIcarusShareUri(pageUri, currentOrigin: currentShareOrigin())) {
      _publishDeepLink(pageUri, source: 'web_location');
    }
    return;
  }

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
  final redactedUri = redactDeepLinkUri(uri);
  developer.log('Deep link received [$source]: $redactedUri',
      name: 'deep_link');
  AppErrorReporter.reportInfo(
    'Deep link received [$source]: $redactedUri',
    source: 'deep_link',
  );
  if (!_hasDeepLinkListener) {
    _bufferedDeepLinks.add(uri);
    return;
  }
  _deepLinkUriController.add(uri);
}

Future<void> main(List<String> args) async {
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      appProviderContainer = ProviderContainer(overrides: [
        guardedSignOutRequestProvider.overrideWith(
          (ref) => ref.watch(cloudSignOutRequestProvider),
        ),
      ]);
      await _initializePersistedDebugLog();
      _installGlobalErrorHandlers();
      final cloudBuildConfig = CloudBuildConfig.fromEnvironment(
        isReleaseMode: kReleaseMode,
      );

      final launch = HiveStoreLaunch.parse(args);
      final PreparedHiveStore? alternateHiveStore;
      if (kIsWeb) {
        launch.validateForWeb();
        alternateHiveStore = null;
      } else {
        alternateHiveStore = await launch.prepareAlternateStore(
          getDefaultHiveDirectory: getApplicationSupportDirectory,
        );
      }

      await registerDeepLinkProtocol('icarus');
      await _initializeDeepLinkHandling();

      await ensureIcarusSingleInstance(
        launch.fileOpenArgs,
        instanceId: alternateHiveStore?.windowsSingleInstanceId ??
            HiveStoreLaunch.defaultWindowsSingleInstanceId,
      );

      if (kIsWeb) {
        // On web, Hive uses IndexedDB; no path needed.
        await Hive.initFlutter();
      } else {
        final hiveDirectoryPath = alternateHiveStore?.hiveDirectoryPath ??
            (await getApplicationSupportDirectory()).path;
        await getTemporaryDirectory();
        await Hive.initFlutter(hiveDirectoryPath);
        if (alternateHiveStore != null) {
          AppErrorReporter.reportInfo(
            'Using alternate Hive store: $hiveDirectoryPath',
            source: 'main.hiveStore',
          );
        }
      }

      staticDrawingCursor = await CustomMouseCursor.icon(
        CustomIcons.drawcursor,
        size: 12,
        hotX: 6,
        hotY: 6,
        color: Colors.white,
      );
      await initializeShapeRotationCursors();

      registerIcarusAdapters(Hive);

      await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
      await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
      await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
      await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
      await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
      await Hive.openBox<dynamic>(HiveBoxNames.strategyOutboxBox);
      await prepareDurableStrategyOutbox();
      await Hive.openBox<dynamic>(HiveBoxNames.cloudMediaOutboxBox);
      await prepareDurableCloudMediaOutbox();
      await Hive.openBox<int>(HiveBoxNames.pinnedItemsBox);
      await Hive.openBox<dynamic>(AnalyticsService.storageBoxName);

      await MapThemeProfilesProvider.bootstrap();

      await StrategyMigrator.migrateAllStrategies();

      await ConvexClient.initialize(
        ConvexConfig(
          deploymentUrl: cloudBuildConfig.deploymentUrl,
          clientId: cloudBuildConfig.clientId,
          operationTimeout: const Duration(seconds: 30),
          healthCheckQuery: defaultConvexHealthCheckQuery,
        ),
      );

      await Supabase.initialize(
        url: 'https://gjdirtrtgnawqoruavqn.supabase.co',
        anonKey: 'sb_publishable_6M0VCSZCvRFrcgNANWPVWw_U06T_rUo',
        authOptions: const FlutterAuthClientOptions(detectSessionInUri: false),
      );

      await AnalyticsService.instance.initialize();

      // await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).clear();

      if (!kIsWeb) {
        await initializeIcarusDesktopWindow(
          "Icarus: Valorant Strategies & Line ups ${Settings.versionName}",
        );
      }
      runApp(
        UncontrolledProviderScope(
          container: appProviderContainer,
          child: MyApp(data: launch.fileOpenArgs),
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

Future<void> warmUpWebViewEnvironment() {
  if (!isWindowsRuntime) {
    isWebViewWarmupComplete = true;
    return Future.value();
  }

  return _webViewEnvironmentWarmupFuture ??=
      _warmUpWebViewEnvironmentInternal();
}

Future<void> _warmUpWebViewEnvironmentInternal() async {
  try {
    await _initWebViewEnvironment();
  } catch (error, stackTrace) {
    webViewEnvironment = null;
    isWebViewInitialized = false;
    AppErrorReporter.reportWarning(
      'WebView failed to initialize. Youtube embeds will be unavailable.',
      source: 'main.warmUpWebViewEnvironment',
      error: error,
      stackTrace: stackTrace,
    );
  } finally {
    isWebViewWarmupComplete = true;
  }
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
  if (isWindowsRuntime) {
    if (isWebViewInitialized && webViewEnvironment != null) {
      return;
    }

    final dir = await getApplicationSupportDirectory();
    final availableVersion = await WebViewEnvironment.getAvailableVersion();

    if (availableVersion == null) {
      webViewEnvironment = null;
      isWebViewInitialized = false;
      return;
    }

    webViewEnvironment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: path.join(dir.path, 'webview'),
      ),
    );
    isWebViewInitialized = true;
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
  late final DiscordPresenceService _discordPresence;
  ProviderSubscription<StrategyState>? _discordStrategySub;
  ProviderSubscription<MapState>? _discordMapSub;
  ProviderSubscription<AppPreferences>? _discordPreferencesSub;
  ProviderSubscription<List<PlacedAgentNode>>? _discordAgentSub;
  ProviderSubscription<List<PlacedAbility>>? _discordAbilitySub;
  Timer? _discordSyncDebounce;

  Future<void> _loadFromFilePathWithWarning(String filePath) async {
    try {
      await StrategyImportExportService(ref).loadFromFilePath(filePath);
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
    if (uri != null &&
        (uri.scheme.toLowerCase() == 'icarus' ||
            isIcarusShareUri(uri, currentOrigin: currentShareOrigin()))) {
      _handleIncomingUri(uri, source: source);
      return;
    }

    await _loadFromFilePathWithWarning(argument);
  }

  void _handleIncomingUri(Uri uri, {required String source}) {
    final uriText = uri.toString();
    if (!_processedDeepLinks.add(uriText)) {
      developer.log(
        'Ignoring duplicate deep link [$source]: ${redactDeepLinkUri(uri)}',
        name: 'deep_link',
      );
      return;
    }

    final redactedUri = redactDeepLinkUri(uri);
    developer.log('Handling deep link [$source]: $redactedUri',
        name: 'deep_link');
    AppErrorReporter.reportInfo(
      'Handling deep link [$source]: $redactedUri',
      source: 'deep_link',
    );

    unawaited(() async {
      final handledAuth = await ref
          .read(authProvider.notifier)
          .handleAuthCallbackUri(uri, source: source);
      if (handledAuth) {
        if (kIsWeb) {
          replaceBrowserUrl(withoutAuthCallbackParameters(Uri.base));
        }
        return;
      }
      await ref
          .read(shareLinkControllerProvider.notifier)
          .handleIncomingUri(uri, source: source);
    }());
  }

  @override
  void initState() {
    super.initState();
    ref.read(authProvider);
    ref.read(strategyOpQueueProvider);
    ref.read(cloudMediaUploadQueueProvider);
    ref.read(cloudMediaCacheProvider);

    _discordPresence = DiscordPresenceService();
    _discordStrategySub = ref.listenManual(
      strategyProvider,
      (_, __) => _scheduleDiscordSync(),
    );
    _discordMapSub = ref.listenManual(
      mapProvider,
      (_, __) => _scheduleDiscordSync(),
    );
    _discordAgentSub = ref.listenManual(
      agentProvider,
      (_, __) => _scheduleDiscordSync(),
    );
    _discordAbilitySub = ref.listenManual(
      abilityProvider,
      (_, __) => _scheduleDiscordSync(),
    );
    _discordPreferencesSub = ref.listenManual(
      appPreferencesProvider,
      (_, __) => _syncDiscordPresence(),
    );

    unawaited(_syncDiscordPresence());

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(warmUpWebViewEnvironment());

      if (widget.data.isEmpty) return;

      for (final argument in widget.data) {
        AppErrorReporter.reportInfo(
          'Startup argument: ${redactLaunchArgument(argument)}',
          source: 'main.startupArgs',
        );
        unawaited(_handleIncomingArgument(argument, source: 'startup_args'));
      }
    });

    _secondInstanceSub = secondInstanceArgsController.stream.listen((args) {
      if (args.isEmpty) return;

      for (final argument in args) {
        AppErrorReporter.reportInfo(
          'Second-instance argument: ${redactLaunchArgument(argument)}',
          source: 'main.secondInstanceArgs',
        );
        unawaited(_handleIncomingArgument(argument, source: 'second_instance'));
      }
    });

    _deepLinkSub = _deepLinkUriController.stream.listen(
      (uri) => _handleIncomingUri(uri, source: 'app_links'),
    );
    _hasDeepLinkListener = true;
    if (_bufferedDeepLinks.isNotEmpty) {
      final pendingUris = List<Uri>.from(_bufferedDeepLinks);
      _bufferedDeepLinks.clear();
      for (final uri in pendingUris) {
        _deepLinkUriController.add(uri);
      }
    }
  }

  @override
  void dispose() {
    _secondInstanceSub?.cancel();
    _deepLinkSub?.cancel();
    _hasDeepLinkListener = false;
    _discordSyncDebounce?.cancel();
    _discordStrategySub?.close();
    _discordMapSub?.close();
    _discordAgentSub?.close();
    _discordAbilitySub?.close();
    _discordPreferencesSub?.close();
    unawaited(_discordPresence.dispose());
    super.dispose();
  }

  /// Coalesces rapid state changes (e.g. placing several agents in a row)
  /// into one presence update, keeping well under Discord's rate limit.
  void _scheduleDiscordSync() {
    _discordSyncDebounce?.cancel();
    _discordSyncDebounce = Timer(
      const Duration(seconds: 2),
      () => unawaited(_syncDiscordPresence()),
    );
  }

  Future<void> _syncDiscordPresence() async {
    if (!mounted) return;

    final preferences = ref.read(appPreferencesProvider);
    if (!preferences.discordPresenceEnabled) {
      await _discordPresence.clear();
      return;
    }

    await _discordPresence.update(
      DiscordPresenceData.fromAppState(
        strategy: ref.read(strategyProvider),
        map: ref.read(mapProvider),
        agentCount: ref.read(agentProvider).length,
        abilityCount: ref.read(abilityProvider).length,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authProvider, (_, next) {
      if (next.isAuthenticated && next.isConvexUserReady) {
        unawaited(
          ref
              .read(shareLinkControllerProvider.notifier)
              .redeemPendingIfPossible(),
        );
      }
    });

    return ToastificationWrapper(
      config: const ToastificationConfig(
        alignment: Alignment.bottomCenter,
        // itemWidth: 440,
        animationDuration: Duration(milliseconds: 500),
        blockBackgroundInteraction: false,
      ),
      child: ShadApp(
        navigatorKey: appNavigatorKey,
        navigatorObservers: [mouseNavigationRouteObserver],
        themeMode: ThemeMode.dark,
        darkTheme: ShadThemeData(
          brightness: Brightness.dark,
          colorScheme: Settings.tacticalVioletTheme,
          breadcrumbTheme: const ShadBreadcrumbTheme(separatorSize: 18),
          // Dialogs are panels: one surface step above the canvas, so they
          // read as a sheet rather than a black box on a black screen.
          // Fields keep the panel's surface and take the lighter input
          // edge, so they read on a card without becoming a dark well.
          inputTheme: ShadInputTheme(
            decoration: ShadDecoration(
              border: ShadBorder.all(
                width: 1,
                color: Settings.tacticalVioletTheme.input,
                radius: const BorderRadius.all(Radius.circular(6)),
              ),
            ),
          ),
          primaryDialogTheme: Settings.dialogTheme,
          alertDialogTheme: Settings.dialogTheme,
          // Ghost buttons are quiet controls (menu items, icon buttons),
          // not primary commands, so they don't get the command color.
          ghostButtonTheme: ShadButtonTheme(
            foregroundColor: Settings.tacticalVioletTheme.foreground,
          ),
          outlineButtonTheme: ShadButtonTheme(
            foregroundColor: Settings.tacticalVioletTheme.foreground,
          ),
          // Primary commands are raised like the selected tab: a lighter top
          // of the fill, a bright 1px edge inside the top, a 1px shadow
          // beneath. A rounded Border must be one color, so the theme paints
          // the top light only and the gradient carries the bottom shade.
          primaryButtonTheme: ShadButtonTheme(
            decoration: ShadDecoration(
              gradient: Settings.raisedPrimaryFill,
              shadows: const [Settings.raisedDropShadow],
              border: const ShadBorder(
                radius: BorderRadius.all(Radius.circular(6)),
                top: ShadBorderSide(color: Settings.raisedTopLight, width: 1),
              ),
            ),
          ),
          // Destructive commands are raised the same way, in red.
          destructiveButtonTheme: ShadButtonTheme(
            decoration: ShadDecoration(
              gradient: Settings.raisedDestructiveFill,
              shadows: const [Settings.raisedDropShadow],
              border: const ShadBorder(
                radius: BorderRadius.all(Radius.circular(6)),
                top: ShadBorderSide(color: Settings.raisedTopLight, width: 1),
              ),
            ),
          ),
        ),
        home: const MyHomePage(),
        routes: {
          Routes.folderNavigator: (context) => const FolderNavigator(),
          Routes.strategyView: (context) => const StrategyView(),
          Routes.settings: (context) => const SettingsTab(),
        },
        builder: (context, child) {
          return GlobalShortcuts(
            child: MouseNavigation(child: child ?? const SizedBox.shrink()),
          );
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
