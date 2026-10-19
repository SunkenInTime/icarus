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
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/services/cloud_needs_connection.dart';
import 'package:icarus/widgets/dialogs/share_links_dialog.dart';
import 'package:toastification/toastification.dart';
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

CloudStrategyEntry _cloudStrategy(
  String id,
  String name, {
  List<AgentType> agentTypes = const [],
}) =>
    (
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
      agentTypes: agentTypes,
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
      answerOrder: nextCloudLibraryAnswerOrder(),
      matchedAt: matchedAt,
    );
    await store.writeStrategies(
      _scope,
      const CloudStrategyListing.owned(null),
      [
        _cloudStrategy(
          's1',
          'B Split Retake',
          // Most used first, the way the server sends them.
          agentTypes: const [AgentType.sova, AgentType.jett],
        ),
      ],
      answerOrder: nextCloudLibraryAnswerOrder(),
      matchedAt: matchedAt,
    );
    await store.writeStrategies(
      _scope,
      const CloudStrategyListing.shared(null),
      [_cloudStrategy('s2', 'Team Lotus Default')],
      answerOrder: nextCloudLibraryAnswerOrder(),
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
      child: ToastificationWrapper(
        child: ShadApp(
          home: Scaffold(
            body: FolderContent(folder: folder, onCreateStrategy: () {}),
          ),
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
    // Its card shows its agents, in the role order a local card uses.
    final jett =
        find.image(AssetImage(AgentData.agents[AgentType.jett]!.iconPath));
    final sova =
        find.image(AssetImage(AgentData.agents[AgentType.sova]!.iconPath));
    expect(jett, findsOneWidget);
    expect(sova, findsOneWidget);
    expect(tester.getTopLeft(jett).dx, lessThan(tester.getTopLeft(sova).dx));
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

  testWidgets('with no copy kept (the web), Shared is exactly as before',
      (tester) async {
    await tester.pumpWidget(app(
      const UnavailableCloudLibraryCopyStore(),
      _auth(ConvexAuthStatus.offline),
      workspace: LibraryWorkspace.cloud,
      section: CloudLibrarySection.sharedWithMe,
    ));
    await tester.pump(const Duration(milliseconds: 300));

    final container =
        ProviderScope.containerOf(tester.element(find.byType(FolderContent)));
    expect(container.read(cloudLibraryShowsCopyProvider), isFalse);
    expect(container.read(isCloudLibraryBrowsableProvider), isFalse);
    expect(find.byKey(const ValueKey('cloud-unavailable')), findsOneWidget);
    expect(find.text("Shared isn't on this computer yet"), findsNothing);
  });

  testWidgets(
      'offline, adding a shared link is refused at once, with the reason',
      (tester) async {
    final store = await keptLibrary();
    await store.writeStrategies(
      _scope,
      const CloudStrategyListing.shared(null),
      const [],
      answerOrder: nextCloudLibraryAnswerOrder(),
      matchedAt: matchedAt,
    );
    await store.writeFolders(
      _scope,
      [_folder('mine')],
      answerOrder: nextCloudLibraryAnswerOrder(),
      matchedAt: matchedAt,
    );
    await tester.pumpWidget(app(
      store,
      _auth(ConvexAuthStatus.offline),
      workspace: LibraryWorkspace.cloud,
      section: CloudLibrarySection.sharedWithMe,
    ));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const ValueKey('shared-empty-add-item')));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.byType(AddSharedItemDialog), findsNothing);
    expect(find.text(cloudNeedsConnectionMessage), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets(
      'offline, cloud folder changes are refused before reaching the server',
      (tester) async {
    final store = await keptLibrary();
    final repository = _LiveRepository();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        authProvider.overrideWith(
          () => _FixedAuthProvider(_auth(ConvexAuthStatus.offline)),
        ),
        cloudLibraryCopyStoreProvider.overrideWithValue(store),
        cloudCopyDeploymentUrlProvider.overrideWithValue(_deployment),
        convexStrategyRepositoryProvider.overrideWithValue(repository),
        libraryWorkspaceProvider
            .overrideWith(() => _Workspace(LibraryWorkspace.cloud)),
        folderProvider.overrideWith(() => _OpenFolder('mine')),
      ],
      child: const ToastificationWrapper(
        child: ShadApp(home: Scaffold(body: SizedBox())),
      ),
    ));
    final container =
        ProviderScope.containerOf(tester.element(find.byType(SizedBox)));
    final folders = container.read(folderProvider.notifier);

    await expectLater(
      folders.createFolder(
        name: 'New',
        iconId: 1,
        color: FolderColor.blue,
        workspace: LibraryWorkspace.cloud,
      ),
      throwsStateError,
    );
    final deleted = await folders.deleteFolder(
      'mine',
      workspace: LibraryWorkspace.cloud,
    );
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(deleted.didSucceed, isFalse);
    expect(repository.calls, isEmpty);
    expect(find.text(cloudNeedsConnectionMessage), findsWidgets);
    await tester.pump(const Duration(seconds: 4));
  });

  test(
      'after the socket drops, a list is not marked current again until a '
      'fresh answer arrives', () async {
    final store = _RecordingStore();
    final repository = _LiveRepository();
    final socket = StreamController<bool>.broadcast();
    addTearDown(socket.close);
    final container = ProviderContainer(overrides: [
      authProvider.overrideWith(
        () => _FixedAuthProvider(_auth(ConvexAuthStatus.ready)),
      ),
      cloudLibraryCopyStoreProvider.overrideWithValue(store),
      cloudCopyDeploymentUrlProvider.overrideWithValue(_deployment),
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      convexConnectionProvider.overrideWith((ref) async* {
        yield true;
        yield* socket.stream;
      }),
      folderProvider.overrideWith(() => _OpenFolder(null)),
    ]);
    addTearDown(container.dispose);
    final connection = container.listen(convexConnectionProvider, (_, __) {});
    addTearDown(connection.close);
    await container.read(convexConnectionProvider.future);
    final list = container.listen(cloudStrategiesProvider, (_, __) {});
    await Future<void>.delayed(Duration.zero);

    repository.strategies.add([_cloudStrategy('s1', 'B Split Retake')]);
    await Future<void>.delayed(Duration.zero);
    expect(store.strategyWrites, 1);

    socket.add(false);
    await Future<void>.delayed(Duration.zero);
    // Marked as matching up to the drop.
    expect(store.strategyWrites, 2);

    socket.add(true);
    await Future<void>.delayed(Duration.zero);
    list.close();
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    // Disposed while connected, but nothing was answered since the drop.
    expect(store.strategyWrites, 2);
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
  _LiveRepository() : this._(_NoTransport());

  _LiveRepository._(this._transport) : super(IcarusConvexApi(_transport));

  final _NoTransport _transport;

  /// Every server call this repository was asked to make.
  List<String> get calls => _transport.calls;

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
  final calls = <String>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add('${invocation.memberName}');
    throw UnimplementedError();
  }
}

class _RecordingStore extends MemoryCloudLibraryCopyStore {
  int strategyWrites = 0;

  @override
  Future<void> writeStrategies(
    CloudCopyScope scope,
    CloudStrategyListing listing,
    List<CloudStrategyEntry> strategies, {
    required int answerOrder,
    required DateTime matchedAt,
  }) {
    strategyWrites++;
    return super.writeStrategies(
      scope,
      listing,
      strategies,
      answerOrder: answerOrder,
      matchedAt: matchedAt,
    );
  }
}
