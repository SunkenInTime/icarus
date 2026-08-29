import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';

void main() {
  test('repository maps the typed folder tree into Icarus folders', () async {
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
          'customColorValue': 0xff123456,
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
    expect(folders.single.folder.id, 'folder-1');
    expect(folders.single.folder.iconId, 7);
    expect(folders.single.folder.color, FolderColor.blue);
    expect(folders.single.folder.customColor?.toARGB32(), 0xff123456);
    expect(folders.single.role, 'owner');
  });

  test('repository maps typed strategy rows into Icarus strategies', () async {
    final transport = _RecordingTransport();
    final repository = ConvexStrategyRepository(IcarusConvexApi(transport));
    final firstList = repository.watchStrategiesForFolder(null).first;
    await Future<void>.delayed(Duration.zero);

    transport.emitSubscription(
      'strategies:listForFolder',
      ConvexValue.fromDart([
        {
          'publicId': 'strategy-1',
          'name': 'A Split',
          'mapData': 'ascent',
          'folderPublicId': null,
          'revision': 4,
          'createdAt': 1700000000000,
          'updatedAt': 1700000001000,
          'themeProfileId': null,
          'themeOverridePalette': null,
          'role': 'owner',
          'attackLabel': 'Attack',
        },
      ]),
    );

    final entry = (await firstList).single;
    expect(entry.strategy.id, 'strategy-1');
    expect(entry.strategy.mapData, MapValue.ascent);
    expect(entry.strategy.folderID, isNull);
    expect(
      entry.strategy.lastEdited,
      DateTime.fromMillisecondsSinceEpoch(1700000001000),
    );
    expect(entry.revision, 4);
    expect(entry.role, 'owner');
    expect(entry.attackLabel, 'Attack');
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
      (
        folder: Folder(
          id: 'owned-root',
          name: 'Owned',
          dateCreated: DateTime(2026),
        ),
        role: 'owner',
      ),
      (
        folder: Folder(
          id: 'shared-root',
          name: 'Shared',
          dateCreated: DateTime(2026),
        ),
        role: 'editor',
      ),
    ]);
    for (var i = 0;
        i < 20 && container.read(cloudFoldersProvider).valueOrNull == null;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    expect(
      container
          .read(cloudFoldersProvider)
          .valueOrNull
          ?.map((entry) => entry.folder.id),
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

  final folders = StreamController<List<CloudFolderEntry>>.broadcast();
  int folderWatchCount = 0;

  @override
  Stream<List<CloudFolderEntry>> watchAllFolders() {
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
