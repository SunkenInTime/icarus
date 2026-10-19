import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/collab/cloud_sync_error_message.dart';
import 'package:icarus/const/update_checker.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/client_upgrade_required_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/desktop_update_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/update_status_provider.dart';
import 'package:icarus/widgets/dialogs/share_links_dialog.dart';
import 'package:icarus/widgets/folder_content.dart';
import 'package:icarus/widgets/text_editing_shortcut_scope.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  late Directory tempDir;

  setUpAll(() => registerIcarusAdapters(Hive));

  setUp(() async {
    CoordinateSystem(playAreaSize: const Size(1280, 720));
    tempDir = await Directory.systemTemp.createTemp('icarus-library-');
    Hive.init(tempDir.path);
    // My Library lists the local store next to the cloud one, so the widget
    // reads these boxes even in cloud mode.
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<int>(HiveBoxNames.pinnedItemsBox);
  });

  tearDown(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  testWidgets('empty library leads to creating a strategy', (tester) async {
    var createCount = 0;
    await tester.pumpWidget(
      _cloudApp(
        FolderContent(onCreateStrategy: () => createCount++),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('library-empty-state')), findsOneWidget);
    expect(find.text('Your library is empty'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('library-empty-create-strategy')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('library-empty-create-strategy')),
    );
    expect(createCount, 1);
  });

  testWidgets('local work shows while the cloud library loads', (tester) async {
    final local = _strategy('local-plan', 'Local Plan');
    await tester.runAsync(() async {
      await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
          .put(local.id, local);
    });
    final cloudStrategies = StreamController<List<CloudStrategyEntry>>();
    addTearDown(cloudStrategies.close);
    await tester.pumpWidget(
      _cloudApp(
        FolderContent(onCreateStrategy: () {}),
        strategies: cloudStrategies.stream,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Local Plan'), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-loading-banner')), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-loading')), findsNothing);

    cloudStrategies.add([
      (
        strategy: _strategy('cloud-plan', 'Cloud Plan'),
        revision: 1,
        role: 'owner',
        attackLabel: 'Attack',
        agentTypes: const [],
      ),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Local Plan'), findsOneWidget);
    expect(find.text('Cloud Plan'), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-loading-banner')), findsNothing);
  });

  testWidgets('cloud folders wait for cloud strategies before showing',
      (tester) async {
    final local = _strategy('local-plan', 'Local Plan');
    await tester.runAsync(() async {
      await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
          .put(local.id, local);
    });
    final cloudFolders = StreamController<List<CloudFolderEntry>>();
    final cloudStrategies = StreamController<List<CloudStrategyEntry>>();
    addTearDown(cloudFolders.close);
    addTearDown(cloudStrategies.close);
    await tester.pumpWidget(
      _cloudApp(
        FolderContent(onCreateStrategy: () {}),
        folders: cloudFolders.stream,
        strategies: cloudStrategies.stream,
      ),
    );
    cloudFolders.add([
      (
        folder: Folder(
          name: 'Cloud Folder',
          id: 'cloud-folder',
          dateCreated: DateTime(2026, 9, 1),
          color: FolderColor.blue,
        ),
        role: 'owner',
        strategyCount: 0,
        mapPeeks: const <MapValue>[],
        agentTypes: const <AgentType>[],
      ),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Local Plan'), findsOneWidget);
    expect(find.text('Cloud Folder'), findsNothing);
    expect(find.byKey(const ValueKey('cloud-loading-banner')), findsOneWidget);

    cloudStrategies.add(const []);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Cloud Folder'), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-loading-banner')), findsNothing);
  });

  testWidgets('a session still connecting to the cloud counts as loading',
      (tester) async {
    final local = _strategy('local-plan', 'Local Plan');
    await tester.runAsync(() async {
      await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
          .put(local.id, local);
    });
    await tester.pumpWidget(
      _cloudApp(
        FolderContent(onCreateStrategy: () {}),
        auth: const AppAuthState(
          isLoading: false,
          isAuthenticated: true,
          isConvexUserReady: false,
          convexAuthStatus: ConvexAuthStatus.configuring,
          user: null,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Local Plan'), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-loading-banner')), findsOneWidget);
  });

  testWidgets('a session that gave up connecting says so, and Retry reconnects',
      (tester) async {
    final local = _strategy('local-plan', 'Local Plan');
    await tester.runAsync(() async {
      await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
          .put(local.id, local);
    });
    final auth = _TestAuthProvider(_cloudUnreachable);
    await tester.pumpWidget(
      _cloudApp(FolderContent(onCreateStrategy: () {}), authNotifier: auth),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Local Plan'), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-error-banner')), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-loading-banner')), findsNothing);

    await tester.tap(find.text('Retry'));
    expect(auth.reconnects, ['library_root_retry']);
  });

  testWidgets('a build the server refuses asks for the update above the root',
      (tester) async {
    final local = _strategy('local-plan', 'Local Plan');
    await tester.runAsync(() async {
      await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
          .put(local.id, local);
    });
    await tester.pumpWidget(
      _cloudApp(
        FolderContent(onCreateStrategy: () {}),
        auth: _cloudUnreachable,
        extraOverrides: [
          appUpdateStatusProvider.overrideWith(
            (ref) async => const UpdateCheckResult(
              isSupported: true,
              isUpdateAvailable: false,
              source: 'test',
            ),
          ),
          desktopUpdateControllerProvider.overrideWithValue(null),
        ],
      ),
    );
    ProviderScope.containerOf(tester.element(find.byType(FolderContent)))
        .read(clientUpgradeRequiredProvider.notifier)
        .noteError(clientUpgradeRequiredQueueError);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Local Plan'), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-upgrade-banner')), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('an empty computer waits for the cloud before saying empty',
      (tester) async {
    final cloudStrategies = StreamController<List<CloudStrategyEntry>>();
    addTearDown(cloudStrategies.close);
    await tester.pumpWidget(
      _cloudApp(
        FolderContent(onCreateStrategy: () {}),
        strategies: cloudStrategies.stream,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('cloud-loading')), findsOneWidget);
    expect(find.text('Your library is empty'), findsNothing);
  });

  testWidgets('empty Shared leads to adding a link or code', (tester) async {
    await tester.pumpWidget(
      _cloudApp(
        FolderContent(onCreateStrategy: () {}),
        section: CloudLibrarySection.sharedWithMe,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('shared-empty-state')), findsOneWidget);
    expect(find.text('Nothing shared with you yet'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('shared-empty-add-item')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('shared-empty-add-item')));
    await tester.pumpAndSettle();

    expect(find.byType(AddSharedItemDialog), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AddSharedItemDialog),
        matching: find.byType(TextEditingShortcutScope),
      ),
      findsOneWidget,
    );
  });
}

Widget _cloudApp(
  Widget child, {
  CloudLibrarySection section = CloudLibrarySection.home,
  Stream<List<CloudFolderEntry>>? folders,
  Stream<List<CloudStrategyEntry>>? strategies,
  AppAuthState auth = _cloudReady,
  _TestAuthProvider? authNotifier,
  List<Override> extraOverrides = const [],
}) {
  return ProviderScope(
    overrides: [
      ...extraOverrides,
      authProvider.overrideWith(() => authNotifier ?? _TestAuthProvider(auth)),
      libraryWorkspaceProvider.overrideWith(_CloudWorkspaceNotifier.new),
      cloudLibrarySectionProvider.overrideWith(
        () => _CloudSectionNotifier(section),
      ),
      cloudFolderTreeProvider.overrideWith(
        (_) => folders ?? Stream.value(const <CloudFolderEntry>[]),
      ),
      cloudStrategiesProvider.overrideWith(
        (_) => strategies ?? Stream.value(const <CloudStrategyEntry>[]),
      ),
    ],
    child: ShadApp(home: Scaffold(body: child)),
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

const _cloudReady = AppAuthState(
  isLoading: false,
  isAuthenticated: true,
  isConvexUserReady: true,
  convexAuthStatus: ConvexAuthStatus.ready,
  user: null,
);

/// Signed in, and setting up the cloud gave up.
const _cloudUnreachable = AppAuthState(
  isLoading: false,
  isAuthenticated: true,
  isConvexUserReady: false,
  convexAuthStatus: ConvexAuthStatus.incident,
  user: null,
);

class _TestAuthProvider extends AuthProvider {
  _TestAuthProvider(this._state);

  final AppAuthState _state;
  final reconnects = <String>[];

  @override
  AppAuthState build() => _state;

  @override
  Future<void> reinitializeConvexAuth({String source = 'manual'}) async {
    reconnects.add(source);
  }
}

class _CloudWorkspaceNotifier extends LibraryWorkspaceNotifier {
  @override
  LibraryWorkspace build() => LibraryWorkspace.cloud;
}

class _CloudSectionNotifier extends CloudLibrarySectionNotifier {
  _CloudSectionNotifier(this._section);

  final CloudLibrarySection _section;

  @override
  CloudLibrarySection build() => _section;
}
