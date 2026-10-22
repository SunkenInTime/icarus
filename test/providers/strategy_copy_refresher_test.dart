import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/collab/cloud_library_copy.dart';
import 'package:icarus/collab/cloud_strategy_copy_box.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_copy_scope_provider.dart';
import 'package:icarus/providers/collab/cloud_media_cache_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_copy_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../collab/strategy_copy_fixtures.dart';

const _deployment = 'https://one.convex.cloud';

/// The scope of [accountId] signing in now: a session of its own.
CloudCopyScope _beginSession(String accountId) =>
    CloudCopyScope.begin(deploymentUrl: _deployment, accountId: accountId);

late CloudCopyScope _scope;

final _connected = StateProvider<bool>((ref) => true);

void main() {
  late _Repository repository;
  late MemoryCloudStrategyCopyStore store;
  late _RecordingMediaCache media;

  ProviderContainer start() {
    final container = ProviderContainer(overrides: [
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      authProvider.overrideWith(_ReadyAuthProvider.new),
      cloudOfflineProvider.overrideWithValue(false),
      convexConnectionSnapshotProvider
          .overrideWith((ref) => ref.watch(_connected)),
      cloudStrategyCopyStoreProvider.overrideWithValue(store),
      cloudCopyScopeProvider.overrideWith((ref) {
        final accountId = ref.watch(authProvider.select((a) => a.user?.id));
        return accountId == null ? null : _beginSession(accountId);
      }),
      cloudMediaCacheProvider.overrideWith(() => media),
    ]);
    addTearDown(container.dispose);
    container.read(strategyCopyRefresherProvider);
    return container;
  }

  setUp(() {
    _scope = _beginSession('account-a');
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
      await store.noteFullRefresh(_scope, id, at: now.subtract(age));
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

  test('a full read that answers after sign-out started writes nothing',
      () async {
    repository.owned = {'one'};
    final gate = Completer<void>();
    repository.fullReadGate = gate;
    final container = start();
    await _settle(pause: false);
    expect(repository.fullReads, ['one']);

    (container.read(authProvider.notifier) as _ReadyAuthProvider)
        .startSigningOut();
    _beginSession('account-a').endSessions();
    await store.deleteAllExcept(null);
    gate.complete();
    await _settle();

    expect(store.entryKeys, isEmpty);
  });

  test('a walk stopped by a dropped connection resumes when it reconnects',
      () async {
    repository.owned = {'one', 'two'};
    repository.unanswered = true;
    final container = start();
    await _settle();
    expect(repository.fullReads, ['one']);

    repository.unanswered = false;
    container.read(_connected.notifier).state = false;
    await _settle(pause: false);
    container.read(_connected.notifier).state = true;
    await _settle();
    await _settle();

    expect(store.keptStrategyIds(_scope), {'one', 'two'});
  });

  test('a strategy whose images did not all download is read again', () async {
    repository.owned = {'one'};
    media.failing = true;
    final container = start();
    await _settle();
    expect(store.keepsStrategy(_scope, 'one'), isTrue);
    expect(store.lastFullRefresh(_scope, 'one'), isNull);

    // The next connection walks again, and this time the images come.
    media.failing = false;
    container.read(_connected.notifier).state = false;
    await _settle(pause: false);
    container.read(_connected.notifier).state = true;
    await _settle();
    expect(repository.fullReads, ['one', 'one']);
    expect(store.lastFullRefresh(_scope, 'one'), isNotNull);
  });

  test('a reconnect while a read is still out walks again once it fails',
      () async {
    repository.owned = {'one'};
    final gate = Completer<void>();
    repository.fullReadGate = gate;
    repository.unansweredReads = 1;
    final container = start();
    await _settle(pause: false);
    expect(repository.fullReads, ['one']);

    // The socket drops and comes back while that read is still out...
    container.read(_connected.notifier).state = false;
    await _settle(pause: false);
    container.read(_connected.notifier).state = true;
    await _settle(pause: false);
    // ...then it fails, which used to clear the walk the reconnect wanted.
    repository.fullReadGate = null;
    gate.complete();
    await _settle();
    await _settle();

    expect(store.keptStrategyIds(_scope), {'one'});
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

  test('a full read made elsewhere is kept, and the walk does not repeat it',
      () async {
    repository.owned = {'moved'};
    final gate = Completer<void>();
    repository.listGate = gate;
    final container = start();
    await container.read(strategyCopyRefresherProvider.notifier).keepFullRead(
          repository.snapshotFor('moved'),
          scope: container.read(cloudCopyScopeProvider)!,
          askedAt: DateTime.now(),
        );
    gate.complete();
    await _settle();

    expect(repository.fullReads, isEmpty);
    expect(store.keepsStrategy(_scope, 'moved'), isTrue);
    expect(store.lastFullRefresh(_scope, 'moved'), isNotNull);
    expect(
      media.cached['moved'],
      unorderedEquals(['picture', 'lineup-image']),
    );
  });
}

Future<void> _settle({bool pause = true}) async {
  for (var i = 0; i < 20; i += 1) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  // The pause between background reads.
  if (pause) await Future<void>.delayed(const Duration(seconds: 2));
}

class _Repository extends ConvexStrategyRepository {
  _Repository() : super(IcarusConvexApi(_UnusedTransport()));

  Set<String> owned = {};
  Set<String> sharedDirectly = {};
  Set<String> inSharedFolders = {};
  bool unanswered = false;

  /// How many of the next full reads go unanswered.
  int unansweredReads = 0;
  Completer<void>? listGate;

  /// While set, a full read waits for it before answering.
  Completer<void>? fullReadGate;
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
    await fullReadGate?.future;
    if (unanswered) throw TimeoutException('no answer');
    if (unansweredReads > 0) {
      unansweredReads -= 1;
      throw TimeoutException('no answer');
    }
    return snapshotFor(strategyPublicId);
  }

  RemoteFullStrategySnapshot snapshotFor(String strategyPublicId) {
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
      agentTypes: const [],
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

  /// While true, every download fails.
  bool failing = false;

  @override
  Future<bool> ensureAssetIdsCached({
    required String strategyId,
    required String strategyPublicId,
    required Map<String, RemoteImageAsset> assetsById,
    required Iterable<String> assetIds,
  }) async {
    if (failing) return false;
    cached[strategyId] = [...assetIds];
    return true;
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

  /// Signing out: the status says so at once, and the account stays until
  /// the session is gone (see AuthProvider.signOut).
  void startSigningOut() =>
      state = state.copyWith(convexAuthStatus: ConvexAuthStatus.signedOut);

  void switchTo(String accountId) => state = state.copyWith(
        user: User(
          id: accountId,
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
