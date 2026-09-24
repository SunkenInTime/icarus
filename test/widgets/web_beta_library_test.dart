import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/widgets/dialogs/auth/auth_dialog.dart';
import 'package:icarus/widgets/dialogs/web_beta_dialog.dart';
import 'package:icarus/widgets/folder_content.dart';
import 'package:icarus/widgets/library_title_strip.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  late Directory tempDir;

  setUpAll(() => registerIcarusAdapters(Hive));

  setUp(() async {
    CoordinateSystem(playAreaSize: const Size(1280, 720));
    tempDir = await Directory.systemTemp.createTemp('icarus-web-beta-');
    Hive.init(tempDir.path);
    final strategies =
        await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<int>(HiveBoxNames.pinnedItemsBox);
    // A strategy already saved in this browser (or on this computer).
    final local = _strategy('local-plan', 'Local Plan');
    await strategies.put(local.id, local);
  });

  tearDown(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  group('web beta', () {
    testWidgets('signed out, My Library is one sign-in action',
        (tester) async {
      _desktopWindow(tester);
      await tester.pumpWidget(
        _library(policy: PlatformPolicy.webBeta, signedIn: false),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('library-sign-in-state')),
        findsOneWidget,
      );
      expect(find.text('Local Plan'), findsNothing);
      // Nothing to search, sort, or create until the user is signed in.
      expect(find.byKey(const ValueKey('library-new-strategy')), findsNothing);
      expect(find.byKey(const ValueKey('library-sort-menu')), findsNothing);
      expect(find.byKey(const ValueKey('library-search')), findsNothing);
      expect(find.byKey(const ValueKey('web-beta-tag')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('library-sign-in-action')));
      await tester.pumpAndSettle();
      expect(find.byType(AuthDialog), findsOneWidget);
    });

    testWidgets('while a session restores, the sign-in prompt does not flash',
        (tester) async {
      _desktopWindow(tester);
      await tester.pumpWidget(
        _library(
          policy: PlatformPolicy.webBeta,
          signedIn: false,
          auth: const AppAuthState(
            isLoading: true,
            isAuthenticated: false,
            isConvexUserReady: false,
            convexAuthStatus: ConvexAuthStatus.signedOut,
            user: null,
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('cloud-loading')), findsOneWidget);
      expect(find.byKey(const ValueKey('library-sign-in-state')), findsNothing);
    });

    testWidgets('signed in, My Library lists cloud strategies only',
        (tester) async {
      _desktopWindow(tester);
      await tester.pumpWidget(
        _library(policy: PlatformPolicy.webBeta, signedIn: true),
      );
      await tester.pumpAndSettle();

      expect(find.text('Cloud Plan'), findsOneWidget);
      expect(find.text('Local Plan'), findsNothing);
      expect(find.text('On this device'), findsNothing);

      // New creates cloud work; file import and export stay on desktop.
      await tester.tap(find.byKey(const ValueKey('library-new-menu')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('library-new-folder')), findsOneWidget);
      expect(find.text('Import .ica'), findsNothing);
      expect(find.text('Import Backup'), findsNothing);
      expect(find.text('Export Library'), findsNothing);
    });

    testWidgets('Beta tag explains what is desktop-only and coming',
        (tester) async {
      _desktopWindow(tester);
      await tester.pumpWidget(
        _library(policy: PlatformPolicy.webBeta, signedIn: false),
      );
      await tester.pumpAndSettle();

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
      expect(find.text('Coming to the web beta'), findsOneWidget);
      expect(find.text('Adding images · Adding lineups'), findsOneWidget);
      expect(find.byKey(const ValueKey('web-beta-download')), findsOneWidget);
    });
  });

  group('desktop', () {
    testWidgets('signed out, the local library is listed with no Beta tag',
        (tester) async {
      _desktopWindow(tester);
      await tester.pumpWidget(
        _library(policy: PlatformPolicy.desktop, signedIn: false),
      );
      await tester.pumpAndSettle();

      expect(find.text('Local Plan'), findsOneWidget);
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
      _desktopWindow(tester);
      await tester.pumpWidget(
        _library(policy: PlatformPolicy.desktop, signedIn: true),
      );
      await tester.pumpAndSettle();

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
      expect(
        policy.unavailableMessage(PlatformFeature.addImages),
        'Adding images is coming to the web beta.',
      );
      expect(
        policy.unavailableMessage(PlatformFeature.addLineups),
        'Adding lineups is coming to the web beta.',
      );
      // Coming-to-beta features are their own flag, not desktop-only.
      expect(policy.desktopOnly, isNot(contains(PlatformFeature.addImages)));
      expect(policy.desktopOnly, isNot(contains(PlatformFeature.addLineups)));
      expect(policy.allowsLocalLibrary, isFalse);
      expect(policy.requiresSignIn, isTrue);
    });
  });
}

void _desktopWindow(WidgetTester tester) {
  // The strip needs a desktop-width window; the test font is wide.
  tester.view.physicalSize = const Size(1600, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _library({
  required PlatformPolicy policy,
  required bool signedIn,
  AppAuthState? auth,
}) {
  final authState = auth ??
      AppAuthState(
        isLoading: false,
        isAuthenticated: signedIn,
        isConvexUserReady: signedIn,
        convexAuthStatus:
            signedIn ? ConvexAuthStatus.ready : ConvexAuthStatus.signedOut,
        user: null,
      );
  return ProviderScope(
    overrides: [
      platformPolicyProvider.overrideWithValue(policy),
      authProvider.overrideWith(() => _FixedAuthProvider(authState)),
      libraryWorkspaceProvider.overrideWith(
        () => _FixedWorkspaceNotifier(
          signedIn ? LibraryWorkspace.cloud : LibraryWorkspace.local,
        ),
      ),
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
    child: ShadApp(
      home: Scaffold(
        body: Column(
          children: [
            LibraryTitleStrip(
              onCreateStrategy: () {},
              onCreateFolder: () {},
              onImportIca: () {},
              onImportBackup: () {},
              onExportLibrary: () {},
            ),
            Expanded(child: FolderContent(onCreateStrategy: () {})),
          ],
        ),
      ),
    ),
  );
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

class _FixedAuthProvider extends AuthProvider {
  _FixedAuthProvider(this._state);

  final AppAuthState _state;

  @override
  AppAuthState build() => _state;
}

class _FixedWorkspaceNotifier extends LibraryWorkspaceNotifier {
  _FixedWorkspaceNotifier(this._workspace);

  final LibraryWorkspace _workspace;

  @override
  LibraryWorkspace build() => _workspace;
}
