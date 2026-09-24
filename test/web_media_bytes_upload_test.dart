import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
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
import 'package:icarus/const/hive_boxes.dart';
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
import 'package:toastification/toastification.dart';

// The web beta: no image files, so picked images wait as pending bytes.

const _imageId = 'web-image';
final _imageBytes = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3, 4, 5]);

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
    completedAssetIds.add(assetPublicId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// One browser session. Sharing the stores between two of these is a
/// refresh.
ProviderContainer _webSession({
  required MemoryDurableCloudMediaOutboxStore mediaStore,
  required MemoryPendingMediaBytesStore bytesStore,
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
      cloudMediaAccountIdProvider.overrideWithValue('account-a'),
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'picked bytes are saved before the job, survive a refresh, and upload',
      (tester) async {
    await tester.pumpWidget(
      const ToastificationWrapper(child: MaterialApp(home: SizedBox())),
    );
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
      expect(bytesStore.values[_imageId], _imageBytes);
      expect(mediaStore.values, contains('account-a|$_imageId'));
      first.dispose();
    });

    // Refresh, back online: the restored job sends the restored bytes.
    final repository = _R2Repository();
    final puts = <http.Request>[];
    final client = MockClient((request) async {
      // Both halves were durable before anything was sent.
      expect(bytesStore.values[_imageId], _imageBytes);
      expect(mediaStore.values, contains('account-a|$_imageId'));
      puts.add(request);
      return http.Response('', 200, headers: {'etag': '"etag-1"'});
    });
    final strategyStore = await tester.runAsync(_placedImageOp);
    late ProviderContainer restarted;
    await tester.runAsync(() async {
      await http.runWithClient(() async {
        restarted = _webSession(
          mediaStore: mediaStore,
          bytesStore: bytesStore,
          strategyStore: strategyStore,
          online: true,
          repository: repository,
        );
        expect(restarted.read(pendingMediaBytesProvider)[_imageId],
            _imageBytes);
        final restored = restarted.read(cloudMediaUploadQueueProvider).jobs;
        expect(restored.single.assetPublicId, _imageId);

        await restarted
            .read(cloudMediaUploadQueueProvider.notifier)
            .retryNow(ignoreBackoff: true);
        for (var i = 0;
            i < 40 && repository.completedAssetIds.isEmpty;
            i++) {
          await _settle();
        }
        await _settle();
      }, () => client);
    });
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
    expect(restarted.read(pendingMediaBytesProvider)[_imageId], _imageBytes);
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
        .put('lost-image', _imageBytes);
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

  test('once the page serves an image from the cloud, its bytes are dropped',
      () async {
    final bytesStore = MemoryPendingMediaBytesStore();
    final container = _webSession(
      mediaStore: MemoryDurableCloudMediaOutboxStore(),
      bytesStore: bytesStore,
    );
    addTearDown(container.dispose);
    await container
        .read(pendingMediaBytesProvider.notifier)
        .put(_imageId, _imageBytes);

    await container
        .read(cloudMediaUploadQueueProvider.notifier)
        .reconcilePageMedia(
      strategyPublicId: 'strategy-a',
      placedImages: const [],
      assetsById: {_imageId: _activeAsset(_imageId)},
    );

    expect(container.read(pendingMediaBytesProvider), isEmpty);
    expect(bytesStore.values, isEmpty);
  });

  test('a launch drops restored bytes that no job needs', () async {
    final mediaStore = MemoryDurableCloudMediaOutboxStore();
    await mediaStore.put(CloudMediaUploadJob(
      jobId: 'queued-image',
      accountId: 'account-b',
      strategyPublicId: 'strategy-b',
      assetPublicId: 'queued-image',
      fileExtension: '.png',
      mimeType: 'image/png',
      state: CloudMediaJobState.pendingUpload,
      attempts: 0,
      updatedAt: DateTime.utc(2026, 9, 24),
    ));
    final bytesStore = MemoryPendingMediaBytesStore({
      'queued-image': _imageBytes,
      'abandoned-lineup-image': _imageBytes,
    });
    final container =
        _webSession(mediaStore: mediaStore, bytesStore: bytesStore);
    addTearDown(container.dispose);

    container.read(cloudMediaUploadQueueProvider);
    await _settle();

    // Another account's queued image keeps its bytes.
    expect(bytesStore.values.keys, ['queued-image']);
  });

  test('a launch with unreadable saved work drops no bytes', () async {
    final mediaStore = MemoryDurableCloudMediaOutboxStore({
      'account-a|unreadable': {'outboxVersion': 99},
    });
    final bytesStore =
        MemoryPendingMediaBytesStore({'maybe-needed': _imageBytes});
    final container =
        _webSession(mediaStore: mediaStore, bytesStore: bytesStore);
    addTearDown(container.dispose);

    container.read(cloudMediaUploadQueueProvider);
    await _settle();

    expect(bytesStore.values.keys, ['maybe-needed']);
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
      await Hive.openBox<Uint8List>(HiveBoxNames.pendingMediaBytesBox);
      await HivePendingMediaBytesStore().put(_imageId, _imageBytes);
      await Hive.close();

      await Hive.openBox<Uint8List>(HiveBoxNames.pendingMediaBytesBox);
      final store = HivePendingMediaBytesStore();
      expect(store.load()[_imageId], _imageBytes);
      await store.remove(_imageId);
      expect(store.load(), isEmpty);
    } finally {
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });
}
