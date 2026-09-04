import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/pinned_items_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/cloud_library_action.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDirectory;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'icarus-cloud-library-actions-',
    );
    Hive.init(tempDirectory.path);
    await Hive.openBox<int>(HiveBoxNames.pinnedItemsBox);
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('failed cloud folder delete preserves selection, pin, and streams',
      () async {
    final repository = _ActionRepository()..failDeleteFolder = true;
    final harness = _Harness(repository);
    addTearDown(harness.dispose);
    final notifier = harness.container.read(folderProvider.notifier);
    notifier.updateID('folder-1');
    await harness.container
        .read(pinnedItemsProvider.notifier)
        .togglePin('folder-1');

    final result = await notifier.deleteFolder(
      'folder-1',
      workspace: LibraryWorkspace.cloud,
    );
    await _pumpMicrotasks();

    expect(result.didSucceed, isFalse);
    expect(result.userMessage, "Couldn't delete this cloud folder. Try again.");
    expect(result.userMessage, isNot(contains(_ActionRepository.secret)));
    expect(harness.container.read(folderProvider), 'folder-1');
    expect(harness.container.read(pinnedItemsProvider), contains('folder-1'));
    expect(harness.cloudFolderBuilds, 1);
    expect(harness.allCloudFolderBuilds, 1);
    expect(harness.cloudStrategyBuilds, 1);
    expect(harness.messages, isEmpty);
  });

  test('successful cloud folder delete mutates local UI state once', () async {
    final repository = _ActionRepository();
    final harness = _Harness(repository);
    addTearDown(harness.dispose);
    final notifier = harness.container.read(folderProvider.notifier);
    notifier.updateID('folder-1');
    await harness.container
        .read(pinnedItemsProvider.notifier)
        .togglePin('folder-1');

    final result = await notifier.deleteFolder(
      'folder-1',
      workspace: LibraryWorkspace.cloud,
    );
    await _pumpMicrotasks();

    expect(result.didSucceed, isTrue);
    expect(repository.deleteFolderCalls, 1);
    expect(harness.container.read(folderProvider), isNull);
    expect(
      harness.container.read(pinnedItemsProvider),
      isNot(contains('folder-1')),
    );
    expect(harness.cloudFolderBuilds, 2);
    expect(harness.allCloudFolderBuilds, 2);
    expect(harness.cloudStrategyBuilds, 2);
  });

  test('cloud folder update is awaitable and invalidates only after success',
      () async {
    final gate = Completer<void>();
    final repository = _ActionRepository()..updateFolderGate = gate;
    final harness = _Harness(repository);
    addTearDown(harness.dispose);
    final folder = _folder('folder-1');

    final pending = harness.container.read(folderProvider.notifier).editFolder(
          folder: folder,
          newName: 'Retakes',
          newIconId: folder.iconId,
          newColor: folder.color,
          newCustomColor: folder.customColor,
          workspace: LibraryWorkspace.cloud,
        );
    var completed = false;
    pending.then((_) => completed = true);
    await _pumpMicrotasks();
    expect(completed, isFalse);
    expect(harness.cloudFolderBuilds, 1);

    gate.complete();
    final result = await pending;
    await _pumpMicrotasks();

    expect(result.didSucceed, isTrue);
    expect(repository.updateFolderCalls, 1);
    expect(harness.cloudFolderBuilds, 2);
    expect(harness.allCloudFolderBuilds, 2);
  });

  test('failed cloud folder update preserves model and does not invalidate',
      () async {
    final repository = _ActionRepository()..failUpdateFolder = true;
    final harness = _Harness(repository);
    addTearDown(harness.dispose);
    final folder = _folder('folder-1');

    final result =
        await harness.container.read(folderProvider.notifier).editFolder(
              folder: folder,
              newName: 'Injected ${_ActionRepository.secret}',
              newIconId: folder.iconId,
              newColor: folder.color,
              newCustomColor: folder.customColor,
              workspace: LibraryWorkspace.cloud,
            );
    await _pumpMicrotasks();

    expect(result.didSucceed, isFalse);
    expect(result.userMessage, isNot(contains(_ActionRepository.secret)));
    expect(folder.name, 'Defaults');
    expect(harness.cloudFolderBuilds, 1);
    expect(harness.allCloudFolderBuilds, 1);
    expect(harness.messages, isEmpty);
  });

  test('failed cloud folder move is awaitable, visible, and does not refresh',
      () async {
    final gate = Completer<void>();
    final repository = _ActionRepository()
      ..moveFolderGate = gate
      ..failMoveFolder = true;
    final harness = _Harness(repository);
    addTearDown(harness.dispose);

    final pending =
        harness.container.read(folderProvider.notifier).moveToFolder(
              folderID: 'folder-1',
              parentID: 'folder-2',
              workspace: LibraryWorkspace.cloud,
            );
    var completed = false;
    pending.then((_) => completed = true);
    await _pumpMicrotasks();
    expect(completed, isFalse);

    gate.complete();
    final result = await pending;
    await _pumpMicrotasks();

    expect(result.didSucceed, isFalse);
    expect(harness.cloudFolderBuilds, 1);
    expect(harness.allCloudFolderBuilds, 1);
    expect(harness.messages, ["Couldn't move this cloud folder. Try again."]);
    expect(harness.messages.single, isNot(contains(_ActionRepository.secret)));
  });

  test('successful cloud folder move refreshes both folder views once',
      () async {
    final repository = _ActionRepository();
    final harness = _Harness(repository);
    addTearDown(harness.dispose);

    final result =
        await harness.container.read(folderProvider.notifier).moveToFolder(
              folderID: 'folder-1',
              parentID: 'folder-2',
              workspace: LibraryWorkspace.cloud,
            );
    await _pumpMicrotasks();

    expect(result.didSucceed, isTrue);
    expect(repository.moveFolderCalls, 1);
    expect(harness.cloudFolderBuilds, 2);
    expect(harness.allCloudFolderBuilds, 2);
    expect(harness.messages, isEmpty);
  });

  test('cloud strategy delete keeps pin and stream when the server rejects it',
      () async {
    final repository = _ActionRepository()..failDeleteStrategy = true;
    final harness = _Harness(repository);
    addTearDown(harness.dispose);
    await harness.container
        .read(pinnedItemsProvider.notifier)
        .togglePin('strategy-1');

    final result = await harness.container
        .read(strategyProvider.notifier)
        .deleteStrategy('strategy-1', source: StrategySource.cloud);
    await _pumpMicrotasks();

    expect(result.didSucceed, isFalse);
    expect(result.userMessage, isNot(contains(_ActionRepository.secret)));
    expect(harness.container.read(pinnedItemsProvider), contains('strategy-1'));
    expect(harness.cloudStrategyBuilds, 1);
    expect(harness.messages, isEmpty);
  });

  test('cloud strategy delete removes pin and refreshes only after success',
      () async {
    final repository = _ActionRepository();
    final harness = _Harness(repository);
    addTearDown(harness.dispose);
    await harness.container
        .read(pinnedItemsProvider.notifier)
        .togglePin('strategy-1');

    final result = await harness.container
        .read(strategyProvider.notifier)
        .deleteStrategy('strategy-1', source: StrategySource.cloud);
    await _pumpMicrotasks();

    expect(result.didSucceed, isTrue);
    expect(repository.deleteStrategyCalls, 1);
    expect(
      harness.container.read(pinnedItemsProvider),
      isNot(contains('strategy-1')),
    );
    expect(harness.cloudStrategyBuilds, 2);
  });

  test('failed cloud strategy move is awaitable, visible, and does not refresh',
      () async {
    final gate = Completer<void>();
    final repository = _ActionRepository()
      ..moveStrategyGate = gate
      ..failMoveStrategy = true;
    final harness = _Harness(repository);
    addTearDown(harness.dispose);

    final pending =
        harness.container.read(strategyProvider.notifier).moveToFolder(
              strategyID: 'strategy-1',
              parentID: 'folder-2',
              source: StrategySource.cloud,
            );
    var completed = false;
    pending.then((_) => completed = true);
    await _pumpMicrotasks();
    expect(completed, isFalse);

    gate.complete();
    final result = await pending;
    await _pumpMicrotasks();

    expect(result.didSucceed, isFalse);
    expect(harness.cloudStrategyBuilds, 1);
    expect(
      harness.messages,
      ["Couldn't move this cloud strategy. Try again."],
    );
    expect(harness.messages.single, isNot(contains(_ActionRepository.secret)));
  });

  test('successful cloud strategy move refreshes the library once', () async {
    final repository = _ActionRepository();
    final harness = _Harness(repository);
    addTearDown(harness.dispose);

    final result =
        await harness.container.read(strategyProvider.notifier).moveToFolder(
              strategyID: 'strategy-1',
              parentID: 'folder-2',
              source: StrategySource.cloud,
            );
    await _pumpMicrotasks();

    expect(result.didSucceed, isTrue);
    expect(repository.moveStrategyCalls, 1);
    expect(harness.cloudStrategyBuilds, 2);
    expect(harness.messages, isEmpty);
  });
}

class _Harness {
  _Harness(this.repository) {
    container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(() => auth),
        libraryWorkspaceProvider.overrideWith(_CloudWorkspaceNotifier.new),
        convexStrategyRepositoryProvider.overrideWithValue(repository),
        cloudLibraryActionReporterProvider.overrideWithValue(
          CloudLibraryActionReporter(
            showMessage: messages.add,
            reportTechnicalFailure: ({
              required source,
              required error,
              required stackTrace,
            }) {},
          ),
        ),
        cloudFoldersProvider.overrideWith((_) {
          cloudFolderBuilds += 1;
          return Stream.value(const []);
        }),
        cloudAllFoldersProvider.overrideWith((_) {
          allCloudFolderBuilds += 1;
          return Stream.value(const []);
        }),
        cloudStrategiesProvider.overrideWith((_) {
          cloudStrategyBuilds += 1;
          return Stream.value(const []);
        }),
      ],
    );
    container.listen(cloudFoldersProvider, (_, __) {}, fireImmediately: true);
    container.listen(
      cloudAllFoldersProvider,
      (_, __) {},
      fireImmediately: true,
    );
    container.listen(
      cloudStrategiesProvider,
      (_, __) {},
      fireImmediately: true,
    );
  }

  final _ActionRepository repository;
  final _ReadyAuthProvider auth = _ReadyAuthProvider();
  final List<String> messages = [];
  late final ProviderContainer container;
  int cloudFolderBuilds = 0;
  int allCloudFolderBuilds = 0;
  int cloudStrategyBuilds = 0;

  void dispose() => container.dispose();
}

class _CloudWorkspaceNotifier extends LibraryWorkspaceNotifier {
  @override
  LibraryWorkspace build() => LibraryWorkspace.cloud;
}

class _ReadyAuthProvider extends AuthProvider {
  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: null,
      );
}

class _ActionRepository extends ConvexStrategyRepository {
  _ActionRepository() : super(IcarusConvexApi(_UnusedTransport()));

  static const secret = 'Bearer super-secret-backend-detail';

  bool failDeleteFolder = false;
  bool failUpdateFolder = false;
  bool failMoveFolder = false;
  bool failDeleteStrategy = false;
  bool failMoveStrategy = false;
  Completer<void>? updateFolderGate;
  Completer<void>? moveFolderGate;
  Completer<void>? moveStrategyGate;
  int deleteFolderCalls = 0;
  int updateFolderCalls = 0;
  int deleteStrategyCalls = 0;
  int moveFolderCalls = 0;
  int moveStrategyCalls = 0;

  @override
  Future<void> deleteFolder(String folderPublicId) async {
    deleteFolderCalls += 1;
    if (failDeleteFolder) throw StateError(secret);
  }

  @override
  Future<void> updateFolder({
    required String folderPublicId,
    String? name,
    int? iconId,
    int? iconCodePoint,
    String? iconFontFamily,
    bool clearIconFontFamily = false,
    String? iconFontPackage,
    bool clearIconFontPackage = false,
    String? color,
    int? customColorValue,
    bool clearCustomColorValue = false,
  }) async {
    updateFolderCalls += 1;
    await updateFolderGate?.future;
    if (failUpdateFolder) throw StateError(secret);
  }

  @override
  Future<void> moveFolder({
    required String folderPublicId,
    String? parentFolderPublicId,
  }) async {
    moveFolderCalls += 1;
    await moveFolderGate?.future;
    if (failMoveFolder) throw StateError(secret);
  }

  @override
  Future<RemoteStrategyShell> fetchShell(String strategyPublicId) async {
    final now = DateTime.utc(2026);
    return RemoteStrategyShell(
      header: RemoteStrategyHeader(
        publicId: strategyPublicId,
        name: 'A Split',
        mapData: 'Ascent',
        revision: 4,
        createdAt: now,
        updatedAt: now,
      ),
      pages: const [],
    );
  }

  @override
  Future<void> deleteStrategy({
    required String strategyPublicId,
    required int expectedRevision,
  }) async {
    deleteStrategyCalls += 1;
    if (failDeleteStrategy) throw StateError(secret);
  }

  @override
  Future<void> moveStrategy({
    required String strategyPublicId,
    String? folderPublicId,
    required int expectedRevision,
  }) async {
    moveStrategyCalls += 1;
    await moveStrategyGate?.future;
    if (failMoveStrategy) throw StateError(secret);
  }
}

Folder _folder(String id) => Folder(
      id: id,
      name: 'Defaults',
      iconId: 0,
      dateCreated: DateTime.utc(2026),
      color: FolderColor.generic,
    );

Future<void> _pumpMicrotasks() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _UnusedTransport implements ConvexTransport {
  @override
  Future<ConvexValue> action(String name, ConvexObject args) =>
      throw UnimplementedError();

  @override
  Future<ConvexValue> mutation(String name, ConvexObject args) =>
      throw UnimplementedError();

  @override
  Future<ConvexValue> query(String name, ConvexObject args) =>
      throw UnimplementedError();

  @override
  Stream<ConvexValue> subscribe(String name, ConvexObject args) =>
      throw UnimplementedError();
}
