import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/pinned_items_provider.dart';

void main() {
  test('failed cloud folder deletion preserves the selected folder', () async {
    final repository = _DeleteFolderRepository(shouldFail: true);
    final container = _createContainer(repository);
    addTearDown(container.dispose);

    final notifier = container.read(folderProvider.notifier);
    notifier.updateID('folder-1');

    notifier.deleteFolder(
      'folder-1',
      workspace: LibraryWorkspace.cloud,
    );
    await repository.deleteAttempted;
    await Future<void>.delayed(Duration.zero);

    expect(container.read(folderProvider), 'folder-1');
  });

  test('successful cloud folder deletion clears the selected folder', () async {
    final repository = _DeleteFolderRepository();
    final container = _createContainer(repository);
    addTearDown(container.dispose);

    final notifier = container.read(folderProvider.notifier);
    notifier.updateID('folder-1');

    notifier.deleteFolder(
      'folder-1',
      workspace: LibraryWorkspace.cloud,
    );
    await repository.deleteAttempted;
    await Future<void>.delayed(Duration.zero);

    expect(container.read(folderProvider), isNull);
  });

  group('deleting a cloud folder', () {
    /// maps > ascent > retakes, each with a strategy, and bind beside it.
    _DeleteFolderRepository library({String? refuseStrategy}) =>
        _DeleteFolderRepository(
          refuseStrategy: refuseStrategy,
          folders: {
            'maps': null,
            'ascent': 'maps',
            'retakes': 'ascent',
            'bind': null,
          },
          strategies: {
            'maps-notes': 'maps',
            'a-split': 'ascent',
            'b-retake': 'retakes',
            'bind-exec': 'bind',
            'loose': null,
          },
        );

    test('deletes its strategies, then its folders, each before its parent',
        () async {
      final repository = library();
      final ops = _Ops();
      final container = _createContainer(repository, ops: ops);
      addTearDown(container.dispose);

      final result = await container
          .read(folderProvider.notifier)
          .deleteFolder('maps', workspace: LibraryWorkspace.cloud);

      expect(result.didSucceed, isTrue);
      expect(repository.folders.keys, ['bind']);
      expect(repository.strategies.keys, ['bind-exec', 'loose']);
      expect(repository.deletedFolders, ['retakes', 'ascent', 'maps']);
      expect(repository.withinFolders, {'maps'});
      expect(
        ops.discarded,
        unorderedEquals(['maps-notes', 'a-split', 'b-retake']),
      );
    });

    test('a refused strategy stops it, and what went is forgotten here',
        () async {
      final repository = library(refuseStrategy: 'b-retake');
      final ops = _Ops();
      final container = _createContainer(repository, ops: ops);
      addTearDown(container.dispose);

      final result = await container
          .read(folderProvider.notifier)
          .deleteFolder('maps', workspace: LibraryWorkspace.cloud);

      expect(result.didSucceed, isFalse);
      expect(repository.folders.keys, ['maps', 'ascent', 'retakes', 'bind']);
      expect(repository.strategies.keys, ['b-retake', 'bind-exec', 'loose']);
      expect(ops.discarded, unorderedEquals(['maps-notes', 'a-split']));
    });
  });
}

ProviderContainer _createContainer(
  ConvexStrategyRepository repository, {
  _Ops? ops,
}) {
  return ProviderContainer(
    overrides: [
      strategyOpQueueProvider.overrideWith(() => ops ?? _Ops()),
      cloudMediaUploadQueueProvider.overrideWith(_Uploads.new),
      libraryWorkspaceProvider.overrideWith(_CloudWorkspaceNotifier.new),
      pinnedItemsProvider.overrideWith(_MemoryPinnedItemsProvider.new),
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      authProvider.overrideWith(_ReadyAuthProvider.new),
      cloudFoldersProvider.overrideWith((_) => const AsyncData([])),
      cloudAllFoldersProvider.overrideWith((_) => Stream.value(const [])),
      cloudStrategiesProvider.overrideWith((_) => Stream.value(const [])),
    ],
  );
}

class _MemoryPinnedItemsProvider extends PinnedItemsProvider {
  @override
  Map<String, int> build() => const {};

  @override
  Future<void> removePin(String id) async {}
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

class _CloudWorkspaceNotifier extends LibraryWorkspaceNotifier {
  @override
  LibraryWorkspace build() => LibraryWorkspace.cloud;
}

/// Records what this device discards for strategies it learns are gone.
class _Ops extends StrategyOpQueueNotifier {
  final discarded = <String>[];

  @override
  StrategyOpQueueState build() =>
      const StrategyOpQueueState(durableLoaded: true);

  @override
  Future<void> discardDeletedStrategy(String strategyPublicId) async =>
      discarded.add(strategyPublicId);
}

class _Uploads extends CloudMediaUploadQueueNotifier {
  @override
  CloudMediaUploadQueueState build() =>
      const CloudMediaUploadQueueState(jobs: [], isProcessing: false);

  @override
  Future<void> clearJobsForStrategy(String strategyPublicId) async {}
}

/// The owner's library on a server that, like the real one, deletes only
/// an empty folder.
class _DeleteFolderRepository extends ConvexStrategyRepository {
  _DeleteFolderRepository({
    this.shouldFail = false,
    this.refuseStrategy,
    Map<String, String?> folders = const {'folder-1': null},
    Map<String, String?> strategies = const {},
  })  : folders = {...folders},
        strategies = {...strategies},
        super(IcarusConvexApi(_UnusedTransport()));

  final bool shouldFail;
  final String? refuseStrategy;
  final Map<String, String?> folders;
  final Map<String, String?> strategies;
  final deletedFolders = <String>[];

  /// The folder each delete said it was inside.
  final withinFolders = <String?>{};
  final _deleteAttempted = Completer<void>();

  Future<void> get deleteAttempted => _deleteAttempted.future;

  @override
  Future<CloudLibraryInventory> fetchInventory() async =>
      (folders: {...folders}, strategies: {...strategies});

  @override
  Future<RemoteStrategyShell> fetchShell(
    String strategyPublicId, {
    String? shareToken,
  }) async =>
      RemoteStrategyShell(
        header: RemoteStrategyHeader(
          publicId: strategyPublicId,
          name: strategyPublicId,
          mapData: 'ascent',
          revision: 4,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
        pages: const [],
      );

  @override
  Future<void> deleteStrategy({
    required String strategyPublicId,
    required int expectedRevision,
    String? withinFolderPublicId,
  }) async {
    withinFolders.add(withinFolderPublicId);
    if (strategyPublicId == refuseStrategy) throw StateError('refused');
    expect(expectedRevision, 4);
    strategies.remove(strategyPublicId);
  }

  @override
  Future<void> deleteFolder(
    String folderPublicId, {
    String? withinFolderPublicId,
  }) async {
    if (!_deleteAttempted.isCompleted) _deleteAttempted.complete();
    withinFolders.add(withinFolderPublicId);
    if (shouldFail) {
      throw StateError('delete rejected');
    }
    if (folders.containsValue(folderPublicId) ||
        strategies.containsValue(folderPublicId)) {
      throw StateError('Folder has children');
    }
    folders.remove(folderPublicId);
    deletedFolders.add(folderPublicId);
  }
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
