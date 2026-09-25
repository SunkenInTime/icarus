import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/durable_cloud_media_outbox.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/collab/pending_media_bytes_store.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/media_bytes_source.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/dialogs/create_lineup_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

// The web beta: no image files, so picked images wait as pending bytes.

const _imageId = 'web-image';
final _imageBytes = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3, 4, 5]);

PendingMediaKey _key(
  String assetId, {
  String accountId = 'account-a',
  String strategyId = 'strategy-a',
}) =>
    (
      accountId: accountId,
      strategyPublicId: strategyId,
      assetPublicId: assetId,
    );

PendingMediaRecord _record(
  String assetId, {
  String accountId = 'account-a',
  Uint8List? bytes,
  Duration age = Duration.zero,
}) =>
    PendingMediaRecord(
      key: _key(assetId, accountId: accountId),
      bytes: bytes ?? _imageBytes,
      savedAt: DateTime.now().subtract(age),
    );

CloudMediaUploadJob _job(
  String assetId, {
  String accountId = 'account-a',
  CloudMediaJobState state = CloudMediaJobState.pendingUpload,
}) =>
    CloudMediaUploadJob(
      jobId: assetId,
      accountId: accountId,
      strategyPublicId: 'strategy-a',
      assetPublicId: assetId,
      fileExtension: '.png',
      mimeType: 'image/png',
      state: state,
      referenceDurable: true,
      provider: state == CloudMediaJobState.pendingAttach ? 'r2' : null,
      uploadId: state == CloudMediaJobState.pendingAttach ? 'upload-1' : null,
      objectKey:
          state == CloudMediaJobState.pendingAttach ? 'object/$assetId' : null,
      attempts: 0,
      updatedAt: DateTime.utc(2026, 9, 24),
    );

class _Auth extends AuthProvider {
  _Auth({required this.ready});
  final bool ready;

  @override
  AppAuthState build() => AppAuthState(
        isLoading: false,
        isAuthenticated: ready,
        isConvexUserReady: ready,
        convexAuthStatus:
            ready ? ConvexAuthStatus.ready : ConvexAuthStatus.signedOut,
        user: null,
      );
}

class _CloudMode extends CloudCollabModeNotifier {
  @override
  CloudCollabModeState build() => const CloudCollabModeState(
        featureFlagEnabled: true,
        forceLocalFallback: false,
      );
}

class _CloudStrategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        strategyId: 'strategy-a',
        strategyName: 'Strategy A',
        source: StrategySource.cloud,
        isOpen: true,
      );
}

class _OpQueue extends StrategyOpQueueNotifier {
  @override
  StrategyOpQueueState build() => const StrategyOpQueueState(
        accountId: 'account-a',
        strategyPublicId: 'strategy-a',
        clientId: 'client-a',
        durableLoaded: true,
      );
}

class _R2Repository implements ConvexStrategyRepository {
  _R2Repository({this.attachGate});

  /// Holds each attach open until completed, to race it with the URL.
  final Completer<void>? attachGate;
  final List<String> completedAssetIds = [];

  @override
  Future<CloudImageUploadIntent> generateImageUploadUrl({
    required String strategyPublicId,
    required String assetPublicId,
    required String mimeType,
    required String fileExtension,
    int? byteSize,
    int? width,
    int? height,
  }) async {
    return CloudImageUploadIntent(
      provider: 'r2',
      uploadId: 'upload-$assetPublicId',
      objectKey: 'strategies/$strategyPublicId/$assetPublicId$fileExtension',
      uploadUrl: 'https://r2.example.com/$assetPublicId',
      requiredHeaders: {'Content-Type': mimeType},
      expiresAt: DateTime.now().add(const Duration(minutes: 15)),
      maxBytes: 0,
    );
  }

  @override
  Future<void> completeImageUpload({
    required String strategyPublicId,
    required String assetPublicId,
    String? provider,
    String? uploadId,
    String? objectKey,
    String? storageId,
    String? etag,
    String? mimeType,
    String? fileExtension,
    int? byteSize,
    int? width,
    int? height,
  }) async {
    await attachGate?.future;
    completedAssetIds.add(assetPublicId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LineUpGroup _breachGroup() => LineUpGroup(
      id: 'breach-group',
      agent: PlacedAgent(
        id: 'breach-agent',
        type: AgentType.breach,
        position: const Offset(180, 220),
        isAlly: true,
      ),
      items: [
        LineUpItem(
          id: 'breach-item',
          ability: PlacedAbility(
            id: 'breach-ability',
            data: AgentData.agents[AgentType.breach]!.abilities.first,
            position: const Offset(320, 360),
            isAlly: true,
          ),
        ),
      ],
    );

/// Holds each write open until [putGate] completes, like a slow IndexedDB.
class _GatedBytesStore extends MemoryPendingMediaBytesStore {
  Completer<void>? putGate;

  @override
  Future<void> put(PendingMediaRecord record) async {
    await putGate?.future;
    await super.put(record);
  }
}

/// Holds each outbox batch write open until [batchGate] completes.
class _GatedOutboxStore extends MemoryDurableCloudMediaOutboxStore {
  Completer<void>? batchGate;

  @override
  Future<void> putAll(Iterable<CloudMediaUploadJob> jobs) async {
    await batchGate?.future;
    await super.putAll(jobs);
  }
}

class _OnePngPicker extends FilePicker {
  _OnePngPicker(this.bytes);
  final Uint8List bytes;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async =>
      FilePickerResult([
        PlatformFile(name: 'smoke.png', size: bytes.length, bytes: bytes),
      ]);
}

/// One browser tab. Sharing the stores between two of these is a second tab
/// or a refresh.
ProviderContainer _webSession({
  required MemoryDurableCloudMediaOutboxStore mediaStore,
  required MemoryPendingMediaBytesStore bytesStore,
  String accountId = 'account-a',
  MemoryDurableStrategyOutboxStore? strategyStore,
  bool online = false,
  ConvexStrategyRepository? repository,
}) {
  return ProviderContainer(
    overrides: [
      imageFilesOnDeviceProvider.overrideWithValue(false),
      pendingMediaBytesStoreProvider.overrideWithValue(bytesStore),
      durableCloudMediaOutboxStoreProvider.overrideWithValue(mediaStore),
      durableStrategyOutboxStoreProvider.overrideWithValue(
        strategyStore ?? MemoryDurableStrategyOutboxStore(),
      ),
      if (repository != null)
        convexStrategyRepositoryProvider.overrideWithValue(repository),
      authProvider.overrideWith(() => _Auth(ready: online)),
      cloudMediaAccountIdProvider.overrideWithValue(accountId),
      cloudCollabModeProvider.overrideWith(_CloudMode.new),
      convexConnectionSnapshotProvider.overrideWithValue(online),
      convexConnectionProvider.overrideWith((ref) => Stream.value(online)),
      strategyProvider.overrideWith(_CloudStrategy.new),
      strategyOpQueueProvider.overrideWith(_OpQueue.new),
      cloudMediaReferenceSnapshotLoaderProvider.overrideWithValue(
        (_) async => throw StateError('no server reads in this test'),
      ),
    ],
  );
}

/// The page op that places the image, already in the durable outbox.
Future<MemoryDurableStrategyOutboxStore> _placedImageOp() async {
  final ops = MemoryDurableStrategyOutboxStore();
  await ops.put(DurableOutboxRecord(
    accountId: 'account-a',
    strategyPublicId: 'strategy-a',
    entityKey: const EntitySyncKey.element('page-a', _imageId),
    pending: const PendingOp(
      clientId: 'client-a',
      op: ElementAddOp(
        opId: 'place-image',
        elementPublicId: _imageId,
        pagePublicId: 'page-a',
        sortIndex: 0,
        payload: {'id': _imageId},
      ),
    ),
    status: DurableOutboxStatus.queued,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  ));
  return ops;
}

RemoteImageAsset _activeAsset(String id) => RemoteImageAsset(
      publicId: id,
      fileExtension: '.png',
      width: 16,
      height: 9,
      url: 'https://media.example.com/$id.png',
      legacyStoragePath: null,
      uploadStatus: 'active',
    );

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 50));

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 60 && !done(); i++) {
    await _settle();
  }
  await _settle();
}

/// Runs [session]'s queue until [repository] has attached [count] images,
/// answering every PUT with 200 and recording it in [puts].
Future<void> _uploadAll(
  ProviderContainer Function() session,
  _R2Repository repository,
  List<http.Request> puts, {
  int count = 1,
}) {
  final client = MockClient((request) async {
    puts.add(request);
    return http.Response('', 200, headers: {'etag': '"etag"'});
  });
  return http.runWithClient(() async {
    final container = session();
    await container
        .read(cloudMediaUploadQueueProvider.notifier)
        .retryNow(ignoreBackoff: true);
    await _until(() => repository.completedAssetIds.length >= count);
  }, () => client);
}

Future<void> _pumpToasts(WidgetTester tester) => tester.pumpWidget(
      const ToastificationWrapper(child: MaterialApp(home: SizedBox())),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'picked bytes are saved before the job, survive a refresh, and upload',
      (tester) async {
    await _pumpToasts(tester);
    final mediaStore = MemoryDurableCloudMediaOutboxStore();
    final bytesStore = MemoryPendingMediaBytesStore();

    // Offline: the picked image is saved and queued, nothing is sent.
    await tester.runAsync(() async {
      final first =
          _webSession(mediaStore: mediaStore, bytesStore: bytesStore);
      await first.read(placedImageProvider.notifier).saveSecureImage(
            _imageBytes,
            _imageId,
            '.png',
            strategyId: 'strategy-a',
          );
      await first
          .read(cloudMediaUploadQueueProvider.notifier)
          .enqueuePlacedImageUpload(
            strategyPublicId: 'strategy-a',
            imagePublicId: _imageId,
            fileExtension: '.png',
          );
      expect(
        bytesStore.values[pendingMediaStorageKey(_key(_imageId))]?.bytes,
        _imageBytes,
      );
      expect(mediaStore.values, contains('account-a|$_imageId'));
      first.dispose();
    });

    // Refresh, back online: the restored job sends the restored bytes.
    final repository = _R2Repository();
    final puts = <http.Request>[];
    final strategyStore = await tester.runAsync(_placedImageOp);
    late ProviderContainer restarted;
    await tester.runAsync(() => _uploadAll(
          () => restarted = _webSession(
            mediaStore: mediaStore,
            bytesStore: bytesStore,
            strategyStore: strategyStore,
            online: true,
            repository: repository,
          ),
          repository,
          puts,
        ));
    addTearDown(restarted.dispose);

    expect(puts, hasLength(1));
    expect(puts.single.method, 'PUT');
    expect(puts.single.bodyBytes, _imageBytes);
    expect(puts.single.headers['Content-Type'], startsWith('image/png'));
    expect(repository.completedAssetIds, [_imageId]);
    // Synced: nothing left to upload and nothing left in browser storage,
    // but the editor keeps painting the bytes until the cloud URL arrives.
    expect(mediaStore.values, isEmpty);
    expect(bytesStore.values, isEmpty);
    expect(
      restarted
          .read(pendingMediaBytesProvider.notifier)
          .bytesFor(_key(_imageId)),
      _imageBytes,
    );
  });

  testWidgets(
      'two accounts with the same asset ID each upload their own bytes, '
      'and one attach leaves the other alone', (tester) async {
    await _pumpToasts(tester);
    final bytesA = Uint8List.fromList([1, 1, 1]);
    final bytesB = Uint8List.fromList([2, 2, 2, 2]);
    const shared = 'shared-image';
    final mediaStore = MemoryDurableCloudMediaOutboxStore();
    await mediaStore.putAll([
      _job(shared, accountId: 'account-a'),
      _job(shared, accountId: 'account-b'),
    ]);
    final bytesStore = MemoryPendingMediaBytesStore([
      _record(shared, accountId: 'account-a', bytes: bytesA),
      _record(shared, accountId: 'account-b', bytes: bytesB),
    ]);

    final repositoryB = _R2Repository();
    final putsB = <http.Request>[];
    late ProviderContainer sessionB;
    await tester.runAsync(() => _uploadAll(
          () => sessionB = _webSession(
            mediaStore: mediaStore,
            bytesStore: bytesStore,
            accountId: 'account-b',
            online: true,
            repository: repositoryB,
          ),
          repositoryB,
          putsB,
        ));
    addTearDown(sessionB.dispose);

    expect(putsB.single.bodyBytes, bytesB);
    expect(mediaStore.values.keys, ['account-a|$shared']);
    expect(
      bytesStore.values.keys,
      [pendingMediaStorageKey(_key(shared, accountId: 'account-a'))],
    );

    // A signs back in; its own upload still has its own bytes.
    final repositoryA = _R2Repository();
    final putsA = <http.Request>[];
    late ProviderContainer sessionA;
    await tester.runAsync(() => _uploadAll(
          () => sessionA = _webSession(
            mediaStore: mediaStore,
            bytesStore: bytesStore,
            online: true,
            repository: repositoryA,
          ),
          repositoryA,
          putsA,
        ));
    addTearDown(sessionA.dispose);

    expect(putsA.single.bodyBytes, bytesA);
    expect(mediaStore.values, isEmpty);
    expect(bytesStore.values, isEmpty);
  });

  test('reconciling as one account never borrows another account\'s bytes',
      () async {
    final bytesStore = MemoryPendingMediaBytesStore([
      _record('a-image', accountId: 'account-a'),
    ]);
    final mediaStore = MemoryDurableCloudMediaOutboxStore();
    final sessionB = _webSession(
      mediaStore: mediaStore,
      bytesStore: bytesStore,
      accountId: 'account-b',
    );
    addTearDown(sessionB.dispose);

    await sessionB
        .read(cloudMediaUploadQueueProvider.notifier)
        .reconcilePageMedia(
      strategyPublicId: 'strategy-a',
      placedImages: [
        PlacedImage(
          id: 'a-image',
          position: Offset.zero,
          aspectRatio: 1,
          scale: 1,
          fileExtension: '.png',
        ),
      ],
      assetsById: const {},
    );

    expect(mediaStore.values, isEmpty);
    expect(bytesStore.values, hasLength(1));
  });

  test('reconciling a page on web reads no image folder', () async {
    final bytesStore = MemoryPendingMediaBytesStore();
    final mediaStore = MemoryDurableCloudMediaOutboxStore();
    final container =
        _webSession(mediaStore: mediaStore, bytesStore: bytesStore);
    addTearDown(container.dispose);
    final queue = container.read(cloudMediaUploadQueueProvider.notifier);
    final image = PlacedImage(
      id: 'lost-image',
      position: Offset.zero,
      aspectRatio: 1,
      scale: 1,
      fileExtension: '.png',
    );

    // No bytes here and no folder to look in: the image is skipped.
    await queue.reconcilePageMedia(
      strategyPublicId: 'strategy-a',
      placedImages: [image],
      assetsById: const {},
    );
    expect(container.read(cloudMediaUploadQueueProvider).jobs, isEmpty);

    // Bytes still pending from this browser are queued again.
    await container
        .read(pendingMediaBytesProvider.notifier)
        .put(_key('lost-image'), _imageBytes);
    await queue.reconcilePageMedia(
      strategyPublicId: 'strategy-a',
      placedImages: [image],
      assetsById: const {},
    );
    expect(
      container.read(cloudMediaUploadQueueProvider).jobs.single.assetPublicId,
      'lost-image',
    );
  });

  group('the painted copy goes once attached and served from the cloud', () {
    Future<void> race({required bool urlFirst}) async {
      final gate = Completer<void>();
      final repository = _R2Repository(attachGate: gate);
      final bytesStore = MemoryPendingMediaBytesStore([_record(_imageId)]);
      final mediaStore = MemoryDurableCloudMediaOutboxStore();
      await mediaStore.put(
        _job(_imageId, state: CloudMediaJobState.pendingAttach),
      );
      final container = _webSession(
        mediaStore: mediaStore,
        bytesStore: bytesStore,
        online: true,
        repository: repository,
      );
      addTearDown(container.dispose);
      final queue = container.read(cloudMediaUploadQueueProvider.notifier);
      final pending = container.read(pendingMediaBytesProvider.notifier);
      Future<void> serveFromCloud() => queue.reconcilePageMedia(
            strategyPublicId: 'strategy-a',
            placedImages: const [],
            assetsById: {_imageId: _activeAsset(_imageId)},
          );

      await queue.retryNow(ignoreBackoff: true);
      if (urlFirst) {
        // The page serves the URL while the attach is still in flight.
        await serveFromCloud();
        expect(pending.bytesFor(_key(_imageId)), _imageBytes);
      }
      gate.complete();
      await _until(() => repository.completedAssetIds.isNotEmpty);
      expect(bytesStore.values, isEmpty);
      if (!urlFirst) {
        expect(pending.bytesFor(_key(_imageId)), _imageBytes);
        await serveFromCloud();
      }

      expect(pending.bytesFor(_key(_imageId)), isNull);
      expect(container.read(pendingMediaBytesProvider), isEmpty);
    }

    test('attach lands, then the URL arrives', () => race(urlFirst: false));
    test('the URL arrives, then attach lands', () => race(urlFirst: true));
  });

  group('launch prune', () {
    test('a draft another tab is editing survives, then a refresh recovers it',
        () async {
      final mediaStore = MemoryDurableCloudMediaOutboxStore();
      final bytesStore = MemoryPendingMediaBytesStore();
      final tabA = _webSession(mediaStore: mediaStore, bytesStore: bytesStore);
      addTearDown(tabA.dispose);
      tabA.read(cloudMediaUploadQueueProvider);
      final drafts = LineupImageDrafts(
        tabA.read(placedImageProvider.notifier),
        strategyId: 'strategy-a',
      );
      final draft = (await drafts.add(_imageBytes, '.png'))!;

      // Tab B opens while the lineup dialog in tab A is still open.
      final tabB = _webSession(mediaStore: mediaStore, bytesStore: bytesStore);
      addTearDown(tabB.dispose);
      tabB.read(cloudMediaUploadQueueProvider);
      await _settle();
      expect(bytesStore.values, hasLength(1));

      // Tab A saves the lineup, then the browser refreshes.
      drafts.handOver();
      await tabA
          .read(cloudMediaUploadQueueProvider.notifier)
          .enqueueLineupMediaJobs(strategyPublicId: 'strategy-a', images: [
        draft,
      ]);
      final refreshed =
          _webSession(mediaStore: mediaStore, bytesStore: bytesStore);
      addTearDown(refreshed.dispose);
      final jobs = refreshed.read(cloudMediaUploadQueueProvider).jobs;
      await _settle();

      expect(jobs.single.assetPublicId, draft.id);
      expect(
        refreshed
            .read(pendingMediaBytesProvider.notifier)
            .bytesFor(_key(draft.id)),
        _imageBytes,
      );
    });

    test('only a week-old draft with no job is dropped', () async {
      final mediaStore = MemoryDurableCloudMediaOutboxStore();
      await mediaStore.put(_job('old-queued', accountId: 'account-b'));
      final bytesStore = MemoryPendingMediaBytesStore([
        _record('abandoned', age: const Duration(days: 8)),
        _record('old-queued',
            accountId: 'account-b', age: const Duration(days: 8)),
        _record('recent-draft', age: const Duration(days: 1)),
      ]);
      final container =
          _webSession(mediaStore: mediaStore, bytesStore: bytesStore);
      addTearDown(container.dispose);

      container.read(cloudMediaUploadQueueProvider);
      await _settle();

      expect(
        bytesStore.values.keys.toSet(),
        {
          pendingMediaStorageKey(_key('old-queued', accountId: 'account-b')),
          pendingMediaStorageKey(_key('recent-draft')),
        },
      );
    });

    test('unreadable saved work drops no bytes', () async {
      final mediaStore = MemoryDurableCloudMediaOutboxStore({
        'account-a|unreadable': {'outboxVersion': 99},
      });
      final bytesStore = MemoryPendingMediaBytesStore([
        _record('maybe-needed', age: const Duration(days: 30)),
      ]);
      final container =
          _webSession(mediaStore: mediaStore, bytesStore: bytesStore);
      addTearDown(container.dispose);

      container.read(cloudMediaUploadQueueProvider);
      await _settle();

      expect(bytesStore.values, hasLength(1));
    });
  });

  group('lineup drafts', () {
    late _GatedBytesStore bytesStore;
    late ProviderContainer container;
    late LineupImageDrafts drafts;

    setUp(() {
      bytesStore = _GatedBytesStore();
      container = _webSession(
        mediaStore: MemoryDurableCloudMediaOutboxStore(),
        bytesStore: bytesStore,
      );
      drafts = LineupImageDrafts(
        container.read(placedImageProvider.notifier),
        strategyId: 'strategy-a',
      );
    });
    tearDown(() => container.dispose());

    test('removing a draft lets its bytes go', () async {
      final kept = (await drafts.add(_imageBytes, '.png'))!;
      final removed = (await drafts.add(_imageBytes, '.png'))!;

      await drafts.remove(removed.id);

      expect(bytesStore.values.keys, [pendingMediaStorageKey(_key(kept.id))]);
      final painted = container.read(pendingMediaBytesProvider);
      expect(painted.keys, [pendingMediaStorageKey(_key(kept.id))]);
    });

    test('dismissing the dialog lets every draft go', () async {
      await drafts.add(_imageBytes, '.png');
      await drafts.add(_imageBytes, '.png');

      await drafts.dismissed();

      expect(bytesStore.values, isEmpty);
      expect(container.read(pendingMediaBytesProvider), isEmpty);
    });

    test('drafts handed to the queue survive the dialog closing', () async {
      final saved = (await drafts.add(_imageBytes, '.png'))!;
      drafts.handOver();

      await drafts.dismissed();
      await drafts.remove(saved.id);

      expect(bytesStore.values, hasLength(1));
    });

    test('drafts whose queuing failed go when the dialog has closed',
        () async {
      await drafts.add(_imageBytes, '.png');
      final handedOver = drafts.handOver();
      await drafts.dismissed();

      await drafts.takeBack(handedOver);

      expect(bytesStore.values, isEmpty);
    });

    test('a pick that finishes after the dialog closed keeps nothing',
        () async {
      bytesStore.putGate = Completer<void>();
      final pick = drafts.add(_imageBytes, '.png');

      await drafts.dismissed();
      bytesStore.putGate!.complete();

      expect(await pick, isNull);
      expect(bytesStore.values, isEmpty);
      expect(container.read(pendingMediaBytesProvider), isEmpty);
    });

    test('an image over 15 MB is refused before anything is kept', () async {
      final tooLarge = Uint8List(maxCloudImageBytes + 1);

      await expectLater(
        drafts.add(tooLarge, '.png'),
        throwsA(isA<MediaTooLargeException>()),
      );

      expect(bytesStore.values, isEmpty);
      expect(container.read(pendingMediaBytesProvider), isEmpty);
    });
  });

  testWidgets(
      'dismissing while Save queues an edited lineup keeps the queued '
      'image\'s bytes', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final mediaStore = _GatedOutboxStore()..batchGate = Completer<void>();
    final bytesStore = MemoryPendingMediaBytesStore();
    // Disposed at the end of the body, before flutter_test checks timers.
    final container =
        _webSession(mediaStore: mediaStore, bytesStore: bytesStore);
    container
        .read(lineUpProvider.notifier)
        .fromHive(LineUpGraph.fromLegacyGroups([_breachGroup()]));
    final linkId = container.read(lineUpProvider).links.single.id;
    // A real 1x1 PNG: the dialog paints the pick as soon as it is kept.
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
    );
    FilePicker.platform = _OnePngPicker(png);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: ToastificationWrapper(
        child: ShadApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ShadButton(
                onPressed: () => showShadDialog<void>(
                  context: context,
                  builder: (_) => CreateLineupDialog(linkId: linkId),
                ),
                child: const Text('Edit lineup'),
              ),
            ),
          ),
        ),
      ),
    ));

    // Edit the lineup and pick an image.
    await tester.tap(find.text('Edit lineup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Click here to add images'));
    await tester.pumpAndSettle();
    expect(bytesStore.values, hasLength(1));

    // Done, then every way to dismiss while the outbox write is pending.
    await tester.tap(find.text('Done'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    expect(find.byType(CreateLineupDialog), findsOneWidget);

    mediaStore.batchGate!.complete();
    await tester.pumpAndSettle();

    final job = mediaStore.load().jobs.single;
    expect(
      bytesStore.values.keys,
      [pendingMediaStorageKey(_key(job.assetPublicId))],
    );
    expect(
      container.read(lineUpProvider).linkById(linkId)!.images.single.id,
      job.assetPublicId,
    );
    expect(find.byType(CreateLineupDialog), findsNothing);
    // Let any toast from the save time out, then stop the queue's retry
    // timer before the test ends.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });

  test('desktop never opens the pending-bytes box', () async {
    // No Hive box is open here, as on desktop; reading must not need one.
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(imageFilesOnDeviceProvider), isTrue);
    expect(
      container.read(pendingMediaBytesStoreProvider),
      isA<MemoryPendingMediaBytesStore>(),
    );
    expect(container.read(pendingMediaBytesProvider), isEmpty);
    expect(Hive.isBoxOpen(HiveBoxNames.pendingMediaBytesBox), isFalse);
  });

  test('browser storage keeps pending bytes across a reopen', () async {
    final directory = await Directory.systemTemp.createTemp('icarus-bytes-');
    try {
      Hive.init(directory.path);
      await Hive.openBox<dynamic>(HiveBoxNames.pendingMediaBytesBox);
      final savedAt = DateTime.utc(2026, 9, 24, 12);
      await HivePendingMediaBytesStore().put(PendingMediaRecord(
        key: _key(_imageId),
        bytes: _imageBytes,
        savedAt: savedAt,
      ));
      await Hive.close();

      await Hive.openBox<dynamic>(HiveBoxNames.pendingMediaBytesBox);
      final store = HivePendingMediaBytesStore();
      final record = store.load().single;
      expect(record.key, _key(_imageId));
      expect(record.bytes, _imageBytes);
      expect(record.savedAt.isAtSameMomentAs(savedAt), isTrue);
      await store.remove(_key(_imageId));
      expect(store.load(), isEmpty);
    } finally {
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });
}
