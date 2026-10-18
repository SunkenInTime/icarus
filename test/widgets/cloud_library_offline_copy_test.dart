import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/collab/cloud_library_copy.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/widgets/folder_content.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

const _deployment = 'https://prod-1.convex.cloud';
const _scope = CloudCopyScope(deploymentUrl: _deployment, accountId: 'user-a');

const _user = User(
  id: 'user-a',
  appMetadata: <String, dynamic>{},
  userMetadata: <String, dynamic>{},
  aud: 'authenticated',
  createdAt: '2026-10-01T00:00:00.000Z',
);

AppAuthState _auth(ConvexAuthStatus status) => AppAuthState(
      isLoading: false,
      isAuthenticated: true,
      isConvexUserReady: status == ConvexAuthStatus.ready,
      convexAuthStatus: status,
      user: _user,
    );

CloudFolderEntry _folder(String id, {String role = 'owner'}) => (
      folder: Folder(id: id, name: 'Folder $id', dateCreated: DateTime(2026)),
      role: role,
      strategyCount: 1,
      mapPeeks: const [],
      agentTypes: const [],
    );

CloudStrategyEntry _cloudStrategy(String id, String name) => (
      strategy: StrategyData(
        id: id,
        name: name,
        mapData: MapValue.ascent,
        versionNumber: 1,
        lastEdited: DateTime(2026, 10, 1),
        folderID: null,
      ),
      revision: 1,
      role: 'owner',
      attackLabel: 'Attack',
    );

void main() {
  late Directory tempDir;
  final now = DateTime.now();
  final matchedAt = DateTime(now.year, now.month, now.day, 14, 32);

  setUpAll(() => registerIcarusAdapters(Hive));

  setUp(() async {
    CoordinateSystem(playAreaSize: const Size(1280, 720));
    tempDir = await Directory.systemTemp.createTemp('icarus-offline-copy-');
    Hive.init(tempDir.path);
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<int>(HiveBoxNames.pinnedItemsBox);
  });

  tearDown(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  Future<MemoryCloudLibraryCopyStore> keptLibrary() async {
    final store = MemoryCloudLibraryCopyStore();
    await store.writeFolders(
      _scope,
      [_folder('mine'), _folder('theirs', role: 'editor')],
      matchedAt: matchedAt,
    );
    await store.writeStrategies(
      _scope,
      const CloudStrategyListing.owned(null),
      [_cloudStrategy('s1', 'B Split Retake')],
      matchedAt: matchedAt,
    );
    await store.writeStrategies(
      _scope,
      const CloudStrategyListing.shared(null),
      [_cloudStrategy('s2', 'Team Lotus Default')],
      matchedAt: matchedAt,
    );
    return store;
  }

  Widget app(
    CloudLibraryCopyStore store,
    AppAuthState auth, {
    LibraryWorkspace workspace = LibraryWorkspace.local,
    CloudLibrarySection section = CloudLibrarySection.home,
    String? folderId,
    Folder? folder,
  }) {
    return ProviderScope(
      overrides: [
        authProvider.overrideWith(() => _FixedAuthProvider(auth)),
        cloudLibraryCopyStoreProvider.overrideWithValue(store),
        cloudCopyDeploymentUrlProvider.overrideWithValue(_deployment),
        libraryWorkspaceProvider.overrideWith(() => _Workspace(workspace)),
        cloudLibrarySectionProvider.overrideWith(() => _Section(section)),
        folderProvider.overrideWith(() => _OpenFolder(folderId)),
      ],
      child: ShadApp(
        home: Scaffold(
          body: FolderContent(folder: folder, onCreateStrategy: () {}),
        ),
      ),
    );
  }

  testWidgets(
      'offline, My Library shows the kept cloud half with the time it last '
      'matched', (tester) async {
    final store = await keptLibrary();
    await tester.pumpWidget(app(store, _auth(ConvexAuthStatus.offline)));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('B Split Retake'), findsOneWidget);
    expect(find.text('Folder mine'), findsOneWidget);
    // Shared things stay in Shared.
    expect(find.text('Team Lotus Default'), findsNothing);
    expect(find.text('Folder theirs'), findsNothing);
    expect(find.byKey(const ValueKey('cloud-offline-banner')), findsOneWidget);
    expect(
      find.text('Offline. Showing your cloud library as of 2:32 PM. '
          "Changes sync when you're back online."),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('offline with nothing kept keeps the retry banner',
      (tester) async {
    await tester.pumpWidget(
      app(MemoryCloudLibraryCopyStore(), _auth(ConvexAuthStatus.offline)),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('cloud-error-banner')), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('while still connecting, the kept cloud half shows at once',
      (tester) async {
    final store = await keptLibrary();
    await tester.pumpWidget(app(store, _auth(ConvexAuthStatus.configuring)));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('B Split Retake'), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-loading-banner')), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-offline-banner')), findsNothing);
  });

  testWidgets('a session the server rejected shows no copy', (tester) async {
    final store = await keptLibrary();
    await tester.pumpWidget(app(store, _auth(ConvexAuthStatus.incident)));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('B Split Retake'), findsNothing);
    expect(find.byKey(const ValueKey('cloud-error-banner')), findsOneWidget);
  });

  testWidgets('offline, Shared shows what was kept of it', (tester) async {
    final store = await keptLibrary();
    await tester.pumpWidget(app(
      store,
      _auth(ConvexAuthStatus.offline),
      workspace: LibraryWorkspace.cloud,
      section: CloudLibrarySection.sharedWithMe,
    ));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Team Lotus Default'), findsOneWidget);
    expect(find.text('Folder theirs'), findsOneWidget);
    expect(find.text('B Split Retake'), findsNothing);
    expect(find.byKey(const ValueKey('cloud-offline-banner')), findsOneWidget);
  });

  testWidgets('offline, a folder never opened online says it is not kept',
      (tester) async {
    final store = await keptLibrary();
    await tester.pumpWidget(app(
      store,
      _auth(ConvexAuthStatus.offline),
      workspace: LibraryWorkspace.cloud,
      folderId: 'mine',
      folder: _folder('mine').folder,
    ));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('cloud-not-kept')), findsOneWidget);
    expect(find.text("This folder isn't on this computer yet"), findsOneWidget);
    expect(find.text('No strategies in this folder'), findsNothing);
  });

  test('every live answer is written to the copy, for this account only',
      () async {
    final store = MemoryCloudLibraryCopyStore();
    final repository = _LiveRepository();
    final container = ProviderContainer(overrides: [
      authProvider.overrideWith(
        () => _FixedAuthProvider(_auth(ConvexAuthStatus.ready)),
      ),
      cloudLibraryCopyStoreProvider.overrideWithValue(store),
      cloudCopyDeploymentUrlProvider.overrideWithValue(_deployment),
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      folderProvider.overrideWith(() => _OpenFolder(null)),
    ]);
    addTearDown(container.dispose);
    final tree = container.listen(cloudFolderTreeProvider, (_, __) {});
    final list = container.listen(cloudStrategiesProvider, (_, __) {});
    addTearDown(tree.close);
    addTearDown(list.close);
    await Future<void>.delayed(Duration.zero);

    repository.folders.add([_folder('mine')]);
    repository.strategies.add([_cloudStrategy('s1', 'B Split Retake')]);
    await Future<void>.delayed(Duration.zero);

    expect(
      store.readFolders(_scope)?.entries.single.folder.id,
      'mine',
    );
    expect(
      store
          .readStrategies(_scope, const CloudStrategyListing.owned(null))
          ?.entries
          .single
          .strategy
          .name,
      'B Split Retake',
    );
  });
}

class _FixedAuthProvider extends AuthProvider {
  _FixedAuthProvider(this._state);

  final AppAuthState _state;

  @override
  AppAuthState build() => _state;

  @override
  Future<void> reinitializeConvexAuth({String source = 'manual'}) async {}
}

class _Workspace extends LibraryWorkspaceNotifier {
  _Workspace(this._workspace);

  final LibraryWorkspace _workspace;

  @override
  LibraryWorkspace build() => _workspace;
}

class _Section extends CloudLibrarySectionNotifier {
  _Section(this._section);

  final CloudLibrarySection _section;

  @override
  CloudLibrarySection build() => _section;
}

class _OpenFolder extends FolderProvider {
  _OpenFolder(this._folderId);

  final String? _folderId;

  @override
  String? build() => _folderId;
}

class _LiveRepository extends ConvexStrategyRepository {
  _LiveRepository() : super(IcarusConvexApi(_NoTransport()));

  final folders = StreamController<List<CloudFolderEntry>>.broadcast();
  final strategies = StreamController<List<CloudStrategyEntry>>.broadcast();

  @override
  Stream<List<CloudFolderEntry>> watchAllFolders() => folders.stream;

  @override
  Stream<List<CloudStrategyEntry>> watchStrategiesForFolder(
    String? folderPublicId, {
    String scope = 'owned',
  }) =>
      strategies.stream;
}

class _NoTransport implements ConvexTransport {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
