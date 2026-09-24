import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/update_checker.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/desktop_update_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/update_status_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/widgets/dialogs/auth/auth_dialog.dart';
import 'package:icarus/widgets/dialogs/web_beta_dialog.dart';
import 'package:icarus/widgets/folder_navigator.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

/// The library as a user reaches it: the real FolderNavigator, workspace,
/// navigation, and create dialogs. Only auth and the Convex repository are
/// stand-ins.
void main() {
  late Directory tempDir;

  setUpAll(() => registerIcarusAdapters(Hive));

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('icarus-web-beta-');
    Hive.init(tempDir.path);
    final strategies =
        await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    final folders = await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<int>(HiveBoxNames.pinnedItemsBox);
    await Hive.openBox<dynamic>(HiveBoxNames.strategyOutboxBox);
    await Hive.openBox<dynamic>(HiveBoxNames.cloudMediaOutboxBox);
    // A new strategy takes the default theme and preferences.
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await MapThemeProfilesProvider.bootstrap();
    // A strategy and folder already saved in this browser (or on this
    // computer).
    final local = _strategy('local-plan', 'Local Plan');
    await strategies.put(local.id, local);
    final folder = Folder(
      name: 'Local Folder',
      id: 'local-folder',
      dateCreated: DateTime(2026, 9, 1),
      color: FolderColor.blue,
    );
    await folders.put(folder.id, folder);
    await strategies.flush();
    await folders.flush();
  });

  tearDown(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  /// The local library's keys and on-disk bytes, to prove nothing wrote to
  /// it. Keys catch a put at once; the bytes catch it once flushed. Hive's
  /// file IO is real, so it runs outside the widget test's fake clock.
  Future<List<Object>> localLibrary(WidgetTester tester) async {
    final strategies = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final folders = Hive.box<Folder>(HiveBoxNames.foldersBox);
    await tester.runAsync(() async {
      await strategies.flush();
      await folders.flush();
    });
    return [
      strategies.keys.toList(),
      folders.keys.toList(),
      for (final name in [HiveBoxNames.strategiesBox, HiveBoxNames.foldersBox])
        File('${tempDir.path}/$name.hive').readAsBytesSync(),
    ];
  }

  group('web beta', () {
    testWidgets('signed out, My Library is one sign-in action',
        (tester) async {
      final before = await localLibrary(tester);
      final app = await _pumpLibrary(
        tester,
        policy: PlatformPolicy.webBeta,
        auth: _signedOut,
      );

      expect(
        find.byKey(const ValueKey('library-sign-in-state')),
        findsOneWidget,
      );
      expect(find.text('Local Plan'), findsNothing);
      expect(find.text('Local Folder'), findsNothing);
      // Nothing to search, sort, or create until the user is signed in.
      expect(find.byKey(const ValueKey('library-new-strategy')), findsNothing);
      expect(find.byKey(const ValueKey('library-sort-menu')), findsNothing);
      expect(find.byKey(const ValueKey('library-search')), findsNothing);
      expect(find.byKey(const ValueKey('web-beta-tag')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('library-sign-in-action')));
      await tester.pumpAndSettle();
      expect(find.byType(AuthDialog), findsOneWidget);
      expect(app.repository.calls, isEmpty);
      expect(await localLibrary(tester), before);
    });

    testWidgets('restoring, then configuring, then ready lands on the cloud',
        (tester) async {
      final before = await localLibrary(tester);
      final app = await _pumpLibrary(
        tester,
        policy: PlatformPolicy.webBeta,
        auth: _restoring,
        settle: false,
      );

      // No login prompt flashes at a returning user.
      expect(find.byKey(const ValueKey('cloud-loading')), findsOneWidget);
      expect(find.byKey(const ValueKey('library-sign-in-state')), findsNothing);

      app.auth.set(_configuring);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('cloud-loading')), findsOneWidget);
      expect(find.byKey(const ValueKey('library-sign-in-state')), findsNothing);

      app.auth.set(_ready);
      await tester.pumpAndSettle();
      expect(app.workspace, LibraryWorkspace.cloud);
      expect(find.text('Cloud Plan'), findsOneWidget);
      expect(find.text('Local Plan'), findsNothing);
      expect(find.text('On this device'), findsNothing);
      expect(await localLibrary(tester), before);
    });

    testWidgets(
        'ready auth while the workspace is still local creates in the cloud',
        (tester) async {
      final before = await localLibrary(tester);
      // The real workspace notifier starts local; the navigator moves it.
      final app = await _pumpLibrary(
        tester,
        policy: PlatformPolicy.webBeta,
        auth: _ready,
      );
      expect(app.workspace, LibraryWorkspace.cloud);

      await tester.tap(find.byKey(const ValueKey('library-new-strategy')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('create-strategy-map-ascent')));
      await _settleToasts(tester);
      expect(app.repository.calls, ['createStrategyWithInitialPage']);

      await tester.tap(find.byKey(const ValueKey('library-new-menu')));
      await tester.pumpAndSettle();
      // Import and export stay in the desktop app.
      expect(find.text('Import .ica'), findsNothing);
      expect(find.text('Import Backup'), findsNothing);
      expect(find.text('Export Library'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('library-new-folder')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('folder-edit-submit')));
      await tester.pumpAndSettle();
      expect(
        app.repository.calls,
        ['createStrategyWithInitialPage', 'createFolder'],
      );

      expect(await localLibrary(tester), before);
    });

    testWidgets('losing auth with the map picker open writes nothing local',
        (tester) async {
      final before = await localLibrary(tester);
      final app = await _pumpLibrary(
        tester,
        policy: PlatformPolicy.webBeta,
        auth: _ready,
      );

      await tester.tap(find.byKey(const ValueKey('library-new-strategy')));
      await tester.pumpAndSettle();
      app.auth.set(_signedOut);
      await tester.pump();
      expect(app.workspace, LibraryWorkspace.local);

      await tester.tap(find.byKey(const ValueKey('create-strategy-map-ascent')));
      await tester.pumpAndSettle();
      // The local branch refused; the user is told, nothing is saved.
      expect(find.text("Couldn't create strategy right now."), findsOneWidget);
      await _settleToasts(tester);

      expect(app.repository.calls, isEmpty);
      expect(await localLibrary(tester), before);
    });

    testWidgets('losing auth with the folder dialog open writes nothing local',
        (tester) async {
      final before = await localLibrary(tester);
      final app = await _pumpLibrary(
        tester,
        policy: PlatformPolicy.webBeta,
        auth: _ready,
      );

      await tester.tap(find.byKey(const ValueKey('library-new-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-new-folder')));
      await tester.pumpAndSettle();
      app.auth.set(_signedOut);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('folder-edit-submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('folder-edit-failure')), findsOneWidget);
      expect(app.repository.calls, isEmpty);
      expect(await localLibrary(tester), before);
    });

    testWidgets('signed in without the cloud offers a retry, not a login',
        (tester) async {
      final app = await _pumpLibrary(
        tester,
        policy: PlatformPolicy.webBeta,
        auth: _unreachable,
      );

      expect(
        find.byKey(const ValueKey('library-cloud-unreachable')),
        findsOneWidget,
      );
      expect(find.text("Couldn't connect to cloud sync. Please retry."),
          findsOneWidget);
      expect(find.byKey(const ValueKey('library-sign-in-action')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('library-cloud-retry')));
      await tester.pumpAndSettle();
      expect(app.auth.reinitializeCalls, 1);

      // Shared cannot open either, and still never asks for a second login.
      await tester.tap(find.byKey(const ValueKey('library-tab-shared')));
      await tester.pumpAndSettle();
      expect(find.byType(AuthDialog), findsNothing);
      expect(
        find.byKey(const ValueKey('library-cloud-unreachable')),
        findsOneWidget,
      );
    });

    testWidgets('Beta tag explains what is desktop-only',
        (tester) async {
      await _pumpLibrary(
        tester,
        policy: PlatformPolicy.webBeta,
        auth: _signedOut,
      );

      await tester.tap(find.byKey(const ValueKey('web-beta-tag')));
      await tester.pumpAndSettle();

      expect(find.byType(WebBetaDialog), findsOneWidget);
      expect(find.text('Icarus web beta'), findsOneWidget);
      expect(find.text('Desktop-only for now'), findsOneWidget);
      expect(
        find.text(
          'Export · Import · Screenshot · Video export · Drag and drop',
        ),
        findsOneWidget,
      );
      // Nothing is waiting to come, so the list is not drawn.
      expect(find.text('Coming to the web beta'), findsNothing);
      expect(find.textContaining('Adding images'), findsNothing);
      expect(find.byKey(const ValueKey('web-beta-download')), findsOneWidget);
    });
  });

  group('desktop', () {
    testWidgets('signed out, the local library is listed with no Beta tag',
        (tester) async {
      await _pumpLibrary(
        tester,
        policy: PlatformPolicy.desktop,
        auth: _signedOut,
      );

      expect(find.text('Local Plan'), findsOneWidget);
      expect(find.text('Local Folder'), findsOneWidget);
      expect(find.byKey(const ValueKey('library-sign-in-state')), findsNothing);
      expect(find.byKey(const ValueKey('web-beta-tag')), findsNothing);
      expect(find.byKey(const ValueKey('library-new-strategy')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('library-new-menu')));
      await tester.pumpAndSettle();
      expect(find.text('Import .ica'), findsOneWidget);
      expect(find.text('Import Backup'), findsOneWidget);
      expect(find.text('Export Library'), findsOneWidget);
    });

    testWidgets('signed in, local and cloud strategies sit side by side',
        (tester) async {
      await _pumpLibrary(
        tester,
        policy: PlatformPolicy.desktop,
        auth: _ready,
      );

      expect(find.text('Cloud Plan'), findsOneWidget);
      expect(find.text('Local Plan'), findsOneWidget);
      expect(find.byKey(const ValueKey('web-beta-tag')), findsNothing);
    });
  });

  group('PlatformPolicy', () {
    test('desktop offers every feature', () {
      for (final feature in PlatformFeature.values) {
        expect(PlatformPolicy.desktop.supports(feature), isTrue);
        expect(PlatformPolicy.desktop.unavailableMessage(feature), isNull);
      }
      expect(PlatformPolicy.desktop.allowsLocalLibrary, isTrue);
      expect(PlatformPolicy.desktop.requiresSignIn, isFalse);
    });

    test('web beta names the feature and why it is missing', () {
      const policy = PlatformPolicy.webBeta;
      expect(
        policy.unavailableMessage(PlatformFeature.exportFiles),
        'Export is desktop-only for now.',
      );
      expect(policy.allowsLocalLibrary, isFalse);
      expect(policy.requiresSignIn, isTrue);
    });

    test('web beta adds images and lineups', () {
      const policy = PlatformPolicy.webBeta;
      for (final feature in [
        PlatformFeature.addImages,
        PlatformFeature.addLineups,
      ]) {
        expect(policy.supports(feature), isTrue);
        expect(policy.unavailableMessage(feature), isNull);
      }
      expect(policy.comingToWebBeta, isEmpty);
    });

    test('a feature coming to the web beta says so', () {
      const policy = PlatformPolicy(
        isWebBeta: true,
        allowsLocalLibrary: false,
        requiresSignIn: true,
        desktopOnly: {},
        comingToWebBeta: {PlatformFeature.addLineups},
      );
      expect(policy.supports(PlatformFeature.addLineups), isFalse);
      expect(
        policy.unavailableMessage(PlatformFeature.addLineups),
        'Adding lineups is coming to the web beta.',
      );
    });
  });
}

const _signedOut = AppAuthState(
  isLoading: false,
  isAuthenticated: false,
  isConvexUserReady: false,
  convexAuthStatus: ConvexAuthStatus.signedOut,
  user: null,
);

const _restoring = AppAuthState(
  isLoading: true,
  isAuthenticated: false,
  isConvexUserReady: false,
  convexAuthStatus: ConvexAuthStatus.signedOut,
  user: null,
);

const _configuring = AppAuthState(
  isLoading: false,
  isAuthenticated: true,
  isConvexUserReady: false,
  convexAuthStatus: ConvexAuthStatus.configuring,
  user: null,
);

const _ready = AppAuthState(
  isLoading: false,
  isAuthenticated: true,
  isConvexUserReady: true,
  convexAuthStatus: ConvexAuthStatus.ready,
  user: null,
);

/// What auth_provider leaves behind when Convex setup fails: the session
/// stays, the cloud does not answer.
const _unreachable = AppAuthState(
  isLoading: false,
  isAuthenticated: true,
  isConvexUserReady: false,
  convexAuthStatus: ConvexAuthStatus.incident,
  user: null,
  errorMessage: "Couldn't connect to cloud sync. Please retry.",
);

class _Library {
  _Library(this.tester, this.auth, this.repository);

  final WidgetTester tester;
  final _TestAuth auth;
  final _RecordingRepository repository;

  LibraryWorkspace get workspace => ProviderScope.containerOf(
        tester.element(find.byType(FolderNavigator)),
      ).read(libraryWorkspaceProvider);
}

Future<_Library> _pumpLibrary(
  WidgetTester tester, {
  required PlatformPolicy policy,
  required AppAuthState auth,
  bool settle = true,
}) async {
  // The strip needs a desktop-width window; the test font is wide.
  tester.view.physicalSize = const Size(1600, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final testAuth = _TestAuth(auth);
  final repository = _RecordingRepository();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        platformPolicyProvider.overrideWithValue(policy),
        authProvider.overrideWith(() => testAuth),
        convexStrategyRepositoryProvider.overrideWithValue(repository),
        appUpdateStatusProvider.overrideWith(
          (ref) async => const UpdateCheckResult(
            isSupported: false,
            isUpdateAvailable: false,
            source: 'test',
          ),
        ),
        desktopUpdateControllerProvider.overrideWithValue(null),
        cloudFolderTreeProvider.overrideWith(
          (_) => Stream.value(const <CloudFolderEntry>[]),
        ),
        cloudStrategiesProvider.overrideWith(
          (_) => Stream.value([
            (
              strategy: _strategy('cloud-plan', 'Cloud Plan'),
              revision: 1,
              role: 'owner',
              attackLabel: 'Attack',
            ),
          ]),
        ),
      ],
      child: const ToastificationWrapper(
        child: ShadApp(home: FolderNavigator()),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return _Library(tester, testAuth, repository);
}

/// Toasts close on a timer; let them run out so no timer outlives the test.
Future<void> _settleToasts(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
}

StrategyData _strategy(String id, String name) {
  final at = DateTime(2026, 9, 1);
  return StrategyData(
    id: id,
    name: name,
    mapData: MapValue.ascent,
    versionNumber: 1,
    folderID: null,
    pages: const [],
    createdAt: at,
    lastEdited: at,
  );
}

class _TestAuth extends AuthProvider {
  _TestAuth(this._initial);

  final AppAuthState _initial;
  int reinitializeCalls = 0;

  @override
  AppAuthState build() => _initial;

  void set(AppAuthState next) => state = next;

  @override
  Future<void> reinitializeConvexAuth({String source = 'manual'}) async {
    reinitializeCalls++;
  }
}

/// Records cloud creates. Strategy creation then fails, so the test stays in
/// the library instead of opening the editor.
class _RecordingRepository extends Fake implements ConvexStrategyRepository {
  final calls = <String>[];

  @override
  Future<void> createStrategyWithInitialPage({
    required String publicId,
    required String name,
    required String mapData,
    required String initialPagePublicId,
    required String initialPageName,
    bool? initialPageIsAutoNamed,
    required bool initialPageIsAttack,
    String? folderPublicId,
    String? themeProfileId,
    Map<String, dynamic>? themeOverridePalette,
    Map<String, dynamic>? initialPageSettings,
  }) async {
    calls.add('createStrategyWithInitialPage');
    throw StateError('Test server does not open strategies.');
  }

  @override
  Future<void> createFolder({
    required String publicId,
    required String name,
    String? parentFolderPublicId,
    int? iconId,
    int? iconCodePoint,
    String? iconFontFamily,
    String? iconFontPackage,
    String? color,
    int? customColorValue,
  }) async {
    calls.add('createFolder');
  }
}
