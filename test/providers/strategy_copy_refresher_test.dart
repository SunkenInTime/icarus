import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/collab/cloud_strategy_copy_box.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_media_cache_provider.dart';
import 'package:icarus/providers/collab/strategy_copy_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../collab/strategy_copy_fixtures.dart';

const _scope = StrategyCopyScope(
  deploymentUrl: 'https://one.convex.cloud',
  accountId: 'account-a',
);

void main() {
  late _Repository repository;
  late MemoryCloudStrategyCopyStore store;
  late _RecordingMediaCache media;

  ProviderContainer start() {
    final container = ProviderContainer(overrides: [
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      authProvider.overrideWith(_ReadyAuthProvider.new),
      cloudOfflineProvider.overrideWithValue(false),
      cloudStrategyCopyStoreProvider.overrideWithValue(store),
      strategyCopyScopeProvider.overrideWithValue(_scope),
      cloudMediaCacheProvider.overrideWith(() => media),
    ]);
    addTearDown(container.dispose);
    container.read(strategyCopyRefresherProvider);
    return container;
  }

  setUp(() {
    repository = _Repository();
    store = MemoryCloudStrategyCopyStore();
    media = _RecordingMediaCache();
  });

  test(
      'once the cloud is ready, every strategy in the library and Shared is '
      'kept with its images', () async {
    repository.owned = {'mine'};
    repository.sharedDirectly = {'shared'};
    repository.inSharedFolders = {'in-folder'};
    start();
    await _settle();

    expect(repository.fullReads, ['mine', 'shared', 'in-folder']);
    for (final id in ['mine', 'shared', 'in-folder']) {
      expect(store.keepsStrategy(_scope, id), isTrue, reason: id);
      expect(store.lastFullRefresh(_scope, id), isNotNull);
    }
    expect(
      media.cached['mine'],
      unorderedEquals(['picture', 'lineup-image']),
    );
  });

  test('a fresh copy is left alone; one a day old is read again', () async {
    repository.owned = {'fresh', 'old'};
    final now = DateTime.now();
    for (final (id, age) in [
      ('fresh', const Duration(hours: 1)),
      ('old', const Duration(hours: 25)),
    ]) {
      await store.writeFullSnapshot(
        _scope,
        repository.answerFor(id),
        askedAt: now.subtract(age),
        arrivedAt: now.subtract(age),
      );
    }
    start();
    await _settle();
    expect(repository.fullReads, ['old']);
  });

  test('a strategy no longer in any list is dropped from the copy', () async {
    await store.writeFullSnapshot(
      _scope,
      repository.answerFor('gone'),
      askedAt: DateTime.now(),
      arrivedAt: DateTime.now(),
    );
    repository.owned = {'mine'};
    start();
    await _settle();
    expect(store.keptStrategyIds(_scope), {'mine'});
  });

  test('an unanswered read stops the walk until the next connection', () async {
    repository.owned = {'one', 'two'};
    repository.unanswered = true;
    start();
    await _settle();
    expect(repository.fullReads, ['one']);
    expect(store.keptStrategyIds(_scope), isEmpty);
  });

  test('a strategy opened online goes ahead of the walk', () async {
    repository.owned = {'one', 'two'};
    final gate = Completer<void>();
    repository.listGate = gate;
    final container = start();
    container
        .read(strategyCopyRefresherProvider.notifier)
        .keepOpenedStrategy('opened');
    gate.complete();
    await _settle();
    expect(repository.fullReads.first, 'opened');
  });
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i += 1) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  // The pause between background reads.
  await Future<void>.delayed(const Duration(seconds: 2));
}

class _Repository extends ConvexStrategyRepository {
  _Repository() : super(IcarusConvexApi(_UnusedTransport()));

  Set<String> owned = {};
  Set<String> sharedDirectly = {};
  Set<String> inSharedFolders = {};
  bool unanswered = false;
  Completer<void>? listGate;
  final fullReads = <String>[];

  ConvexObject answerFor(String id) {
    final answer = fullAnswer(
      ['a', 'b'],
      elements: [imageRow('image', 'a', 'picture')],
      lineups: [lineupRow('lineup', 'b', 'lineup-image')],
      assets: [assetRow('picture'), assetRow('lineup-image')],
    ).toDart();
    return ConvexValue.fromDart(_renamed(answer, id)) as ConvexObject;
  }

  /// [value] with the fixture's strategy id swapped for [id].
  Object? _renamed(Object? value, String id) => switch (value) {
        Map() => {
            for (final entry in value.entries)
              entry.key:
                  (entry.key == 'publicId' && entry.value == 'strategy') ||
                          entry.key == 'strategyPublicId'
                      ? id
                      : _renamed(entry.value, id),
          },
        List() => [for (final item in value) _renamed(item, id)],
        _ => value,
      };

  @override
  Future<CloudLibraryInventory> fetchInventory() async {
    await listGate?.future;
    return (
      folders: <String, String?>{},
      strategies: {for (final id in owned) id: null},
    );
  }

  @override
  Future<List<CloudStrategyEntry>> fetchSharedStrategies() async =>
      [for (final id in sharedDirectly) _entry(id)];

  @override
  Future<List<CloudFolderEntry>> fetchFolders({String scope = 'owned'}) async =>
      inSharedFolders.isEmpty ? const [] : [_folder()];

  @override
  Future<List<CloudStrategyEntry>> fetchStrategiesForFolder(
    String? folderPublicId, {
    String scope = 'owned',
  }) async =>
      [for (final id in inSharedFolders) _entry(id)];

  @override
  Future<RemoteFullStrategySnapshot> fetchFullSnapshot(
    String strategyPublicId, {
    String? shareToken,
  }) async {
    fullReads.add(strategyPublicId);
    if (unanswered) throw TimeoutException('no answer');
    final answer = answerFor(strategyPublicId);
    return RemoteFullStrategySnapshot(
      header: RemoteStrategyHeader(
        publicId: strategyPublicId,
        name: strategyPublicId,
        mapData: 'ascent',
        revision: 1,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
      pages: const [],
      elementsByPage: const {},
      lineupsByPage: const {},
      assetsById: {
        for (final id in ['picture', 'lineup-image'])
          id: RemoteImageAsset(
            publicId: id,
            fileExtension: '.png',
            width: null,
            height: null,
            url: 'https://images.example/$id.png',
            legacyStoragePath: null,
          ),
      },
      serverAnswer: answer,
    );
  }
}

CloudStrategyEntry _entry(String id) => (
      strategy: StrategyData(
        id: id,
        name: id,
        mapData: MapValue.ascent,
        versionNumber: 1,
        lastEdited: DateTime(2026),
        folderID: null,
      ),
      revision: 1,
      role: 'viewer',
      attackLabel: 'Attack',
    );

CloudFolderEntry _folder() => (
      folder: Folder(
        name: 'Shared',
        id: 'shared-folder',
        dateCreated: DateTime(2026),
      ),
      role: 'viewer',
      strategyCount: 1,
      mapPeeks: const [],
      agentTypes: const [],
    );

class _RecordingMediaCache extends CloudMediaCacheNotifier {
  final cached = <String, List<String>>{};

  @override
  Future<void> ensureAssetsCached({
    required String strategyId,
    required String strategyPublicId,
    required Iterable<RemoteImageAsset> assets,
  }) async {
    cached[strategyId] = [for (final asset in assets) asset.publicId];
  }
}

class _ReadyAuthProvider extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: User(
          id: 'account-a',
          appMetadata: const <String, dynamic>{},
          userMetadata: const <String, dynamic>{},
          aud: 'authenticated',
          createdAt: '2026-01-01T00:00:00.000Z',
        ),
      );
}

class _UnusedTransport implements ConvexTransport {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
