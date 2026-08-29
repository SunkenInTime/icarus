import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';

void main() {
  test('repository maps the typed folder tree into Icarus summaries', () async {
    final transport = _RecordingTransport();
    final repository = ConvexStrategyRepository(IcarusConvexApi(transport));
    final firstTree = repository.watchAllFolders().first;
    await Future<void>.delayed(Duration.zero);

    transport.emitSubscription(
      'folders:listTree',
      ConvexValue.fromDart([
        {
          'publicId': 'folder-1',
          'name': 'Defaults',
          'iconId': 7,
          'iconCodePoint': 0xe2c7,
          'iconFontFamily': 'MaterialIcons',
          'iconFontPackage': null,
          'color': 'blue',
          'customColorValue': null,
          'parentFolderPublicId': null,
          'createdAt': 1700000000000,
          'updatedAt': 1700000001000,
          'role': 'owner',
        },
      ]),
    );

    final folders = await firstTree;
    expect(transport.subscriptionCount['folders:listTree'], 1);
    expect(transport.lastArgs['folders:listTree']?.toDart(), {'scope': 'all'});
    expect(folders.single.publicId, 'folder-1');
    expect(folders.single.iconId, 7);
    expect(folders.single.role, 'owner');
    expect(
      folders.single.updatedAt,
      DateTime.fromMillisecondsSinceEpoch(1700000001000),
    );
  });

  test('folder views share one cached tree subscription', () async {
    final repository = _CountingRepository();
    final container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(_ReadyAuthProvider.new),
        convexStrategyRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    final treeSubscription = container.listen(
      cloudFolderTreeProvider,
      (_, __) {},
      fireImmediately: true,
    );
    final allSubscription = container.listen(
      cloudAllFoldersProvider,
      (_, __) {},
      fireImmediately: true,
    );
    final childrenSubscription = container.listen(
      cloudFoldersProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(treeSubscription.close);
    addTearDown(allSubscription.close);
    addTearDown(childrenSubscription.close);
    await Future<void>.delayed(Duration.zero);

    expect(repository.folderWatchCount, 1);

    repository.folders.add([
      CloudFolderSummary(
        publicId: 'owned-root',
        name: 'Owned',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        role: 'owner',
      ),
      CloudFolderSummary(
        publicId: 'shared-root',
        name: 'Shared',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        role: 'editor',
      ),
    ]);
    for (var i = 0;
        i < 20 && container.read(cloudFoldersProvider).valueOrNull == null;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    expect(
      container.read(cloudFoldersProvider).valueOrNull?.map((f) => f.publicId),
      ['owned-root'],
    );
  });
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

class _CountingRepository extends ConvexStrategyRepository {
  _CountingRepository() : super(IcarusConvexApi(_RecordingTransport()));

  final folders = StreamController<List<CloudFolderSummary>>.broadcast();
  int folderWatchCount = 0;

  @override
  Stream<List<CloudFolderSummary>> watchAllFolders() {
    folderWatchCount += 1;
    return folders.stream;
  }
}

class _RecordingTransport implements ConvexTransport {
  final subscriptionCount = <String, int>{};
  final lastArgs = <String, ConvexObject>{};
  final _subscriptions = <String, StreamController<ConvexValue>>{};

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
  Stream<ConvexValue> subscribe(String name, ConvexObject args) {
    subscriptionCount.update(name, (count) => count + 1, ifAbsent: () => 1);
    lastArgs[name] = args;
    return _subscriptions
        .putIfAbsent(name, StreamController<ConvexValue>.broadcast)
        .stream;
  }

  void emitSubscription(String name, ConvexValue value) {
    _subscriptions[name]!.add(value);
  }
}
