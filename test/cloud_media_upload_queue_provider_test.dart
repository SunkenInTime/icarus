import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/durable_cloud_media_outbox.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

class _SignedOutAuthProvider extends AuthProvider {
  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: false,
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.signedOut,
        user: null,
      );
}

class _CloudReadyAuthProvider extends AuthProvider {
  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: null,
      );
}

class _DisabledCloudCollabMode extends CloudCollabModeNotifier {
  @override
  CloudCollabModeState build() => const CloudCollabModeState(
        featureFlagEnabled: false,
        forceLocalFallback: false,
      );
}

class _ActiveCloudStrategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        strategyId: 'strategy-a',
        strategyName: 'Strategy A',
        source: StrategySource.cloud,
        isOpen: true,
      );
}

class _NoOpenStrategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState();
}

class _SettledOpQueue extends StrategyOpQueueNotifier {
  @override
  StrategyOpQueueState build() => const StrategyOpQueueState(
        accountId: 'account-a',
        strategyPublicId: 'strategy-a',
        clientId: 'client-a',
        durableLoaded: true,
      );
}

class _MutableMediaQueue extends CloudMediaUploadQueueNotifier {
  @override
  CloudMediaUploadQueueState build() => const CloudMediaUploadQueueState(
        jobs: [],
        isProcessing: false,
      );

  void replaceJobs(List<CloudMediaUploadJob> jobs) {
    state = CloudMediaUploadQueueState(jobs: jobs, isProcessing: false);
  }
}

class _FixedOpQueue extends StrategyOpQueueNotifier {
  _FixedOpQueue(this.initialState);

  final StrategyOpQueueState initialState;

  @override
  StrategyOpQueueState build() => initialState;
}

class _FailingBatchStore extends MemoryDurableCloudMediaOutboxStore {
  bool failBatch = false;

  @override
  Future<void> putAll(Iterable<CloudMediaUploadJob> jobs) async {
    if (failBatch) {
      throw StateError('batch write failed');
    }
    await super.putAll(jobs);
  }
}

ProviderContainer _container(
  MemoryDurableCloudMediaOutboxStore store, {
  MemoryDurableStrategyOutboxStore? strategyStore,
  StrategyOpQueueState? opQueueState,
  bool strategyOpen = true,
  bool cloudReady = false,
  CloudMediaReferenceSnapshotLoader? referenceSnapshotLoader,
}) {
  final resolvedOpQueueState = opQueueState ??
      (strategyOpen
          ? const StrategyOpQueueState(
              accountId: 'account-a',
              strategyPublicId: 'strategy-a',
              clientId: 'client-a',
              durableLoaded: true,
            )
          : const StrategyOpQueueState(durableLoaded: true));
  return ProviderContainer(
    overrides: [
      durableCloudMediaOutboxStoreProvider.overrideWithValue(store),
      durableStrategyOutboxStoreProvider.overrideWithValue(
        strategyStore ?? MemoryDurableStrategyOutboxStore(),
      ),
      authProvider.overrideWith(
        cloudReady ? _CloudReadyAuthProvider.new : _SignedOutAuthProvider.new,
      ),
      cloudCollabModeProvider.overrideWith(_DisabledCloudCollabMode.new),
      convexConnectionSnapshotProvider.overrideWithValue(cloudReady),
      convexConnectionProvider.overrideWith(
        (ref) => Stream.value(cloudReady),
      ),
      strategyProvider.overrideWith(
        strategyOpen ? _ActiveCloudStrategy.new : _NoOpenStrategy.new,
      ),
      strategyOpQueueProvider.overrideWith(
        () => _FixedOpQueue(resolvedOpQueueState),
      ),
      if (referenceSnapshotLoader != null)
        cloudMediaReferenceSnapshotLoaderProvider.overrideWithValue(
          referenceSnapshotLoader,
        ),
    ],
  );
}

DurableOutboxRecord _durableRecord(StrategyOp op) {
  final entityKey = EntitySyncKey.forStrategyOp(op)!;
  return DurableOutboxRecord(
    accountId: 'account-a',
    strategyPublicId: 'strategy-a',
    entityKey: entityKey,
    pending: PendingOp(op: op, clientId: 'client-a'),
    status: DurableOutboxStatus.queued,
    createdAt: DateTime.utc(2026, 9, 3),
    updatedAt: DateTime.utc(2026, 9, 3),
  );
}

RemoteFullStrategySnapshot _fullSnapshot({
  List<RemoteElement> elements = const [],
  List<RemoteLineup> lineups = const [],
}) {
  final now = DateTime.utc(2026, 9, 3);
  return RemoteFullStrategySnapshot(
    header: RemoteStrategyHeader(
      publicId: 'strategy-a',
      name: 'Strategy A',
      mapData: 'ascent',
      revision: 1,
      createdAt: now,
      updatedAt: now,
    ),
    pages: const [],
    elementsByPage: {'page-a': elements},
    lineupsByPage: {'page-a': lineups},
    assetsById: const {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('restart restores unfinished lineup media from the durable outbox',
      () async {
    final store = MemoryDurableCloudMediaOutboxStore();
    final first = _container(store);

    await first
        .read(cloudMediaUploadQueueProvider.notifier)
        .enqueueLineupMediaJobs(
      strategyPublicId: 'strategy-a',
      images: [
        SimpleImageData(id: 'lineup-image', fileExtension: '.png'),
      ],
    );
    first.dispose();

    final restarted = _container(store);
    addTearDown(restarted.dispose);
    final state = restarted.read(cloudMediaUploadQueueProvider);

    expect(state.outboxIsReliable, isTrue);
    expect(state.jobs, hasLength(1));
    expect(state.jobs.single.assetPublicId, 'lineup-image');
    expect(state.jobs.single.strategyPublicId, 'strategy-a');
    expect(state.jobs.single.fileExtension, '.png');
    expect(state.jobs.single.referenceDurable, isFalse);
  });

  test('restart keeps an interrupted placement staged and non-runnable',
      () async {
    final store = MemoryDurableCloudMediaOutboxStore();
    final first = _container(store);

    await first
        .read(cloudMediaUploadQueueProvider.notifier)
        .enqueuePlacedImageUpload(
          strategyPublicId: 'strategy-a',
          imagePublicId: 'interrupted-image',
          fileExtension: '.png',
        );
    first.dispose();

    final restarted = _container(store);
    addTearDown(restarted.dispose);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final job = restarted.read(cloudMediaUploadQueueProvider).jobs.single;

    expect(job.assetPublicId, 'interrupted-image');
    expect(job.referenceDurable, isFalse);
    expect(job.attempts, 0);
    expect(restarted.read(cloudMediaUploadQueueProvider).isProcessing, isFalse);
  });

  test('restart restores an image job without visiting its page', () async {
    final store = MemoryDurableCloudMediaOutboxStore();
    final first = _container(store);

    await first
        .read(cloudMediaUploadQueueProvider.notifier)
        .enqueueJobForLocalFile(
          strategyPublicId: 'strategy-a',
          assetPublicId: 'unvisited-page-image',
          fileExtension: '.webp',
          width: 640,
          height: 360,
        );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    first.dispose();

    final restarted = _container(store);
    addTearDown(restarted.dispose);
    final restored = restarted
        .read(cloudMediaUploadQueueProvider)
        .jobsForStrategy('strategy-a');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(restored, hasLength(1));
    expect(restored.single.assetPublicId, 'unvisited-page-image');
    expect(restored.single.width, 640);
    expect(restored.single.height, 360);
  });

  test('blocked uploads yield and keep their durable job pending', () async {
    final store = MemoryDurableCloudMediaOutboxStore();
    final container = _container(store);
    addTearDown(container.dispose);

    await container
        .read(cloudMediaUploadQueueProvider.notifier)
        .enqueueJobForLocalFile(
          strategyPublicId: 'strategy-a',
          assetPublicId: 'offline-image',
          fileExtension: '.jpg',
        );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final state = container.read(cloudMediaUploadQueueProvider);
    expect(state.isProcessing, isFalse);
    expect(state.jobs.single.attempts, 0);
    expect(store.values, contains('offline-image'));
  });

  test('lineup staging is atomic when the durable batch write fails', () async {
    final store = _FailingBatchStore();
    final container = _container(store);
    addTearDown(container.dispose);
    await container
        .read(cloudMediaUploadQueueProvider.notifier)
        .enqueueJobForLocalFile(
          strategyPublicId: 'strategy-a',
          assetPublicId: 'existing-image',
          fileExtension: '.png',
        );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    store.failBatch = true;

    await expectLater(
      container
          .read(cloudMediaUploadQueueProvider.notifier)
          .enqueueLineupMediaJobs(
        strategyPublicId: 'strategy-a',
        images: [
          SimpleImageData(id: 'lineup-image-1', fileExtension: '.png'),
          SimpleImageData(id: 'lineup-image-2', fileExtension: '.png'),
        ],
      ),
      throwsA(isA<StateError>()),
    );

    expect(store.values.keys, ['existing-image']);
    expect(
      container
          .read(cloudMediaUploadQueueProvider)
          .jobs
          .map((job) => job.assetPublicId),
      ['existing-image'],
    );
  });

  test('restart promotes a staged lineup batch without opening its strategy',
      () async {
    const lineupOp = LineupAddOp(
      opId: 'lineup-op',
      lineupPublicId: 'lineup-a',
      pagePublicId: 'page-a',
      payload: <String, dynamic>{
        'images': [
          {'id': 'lineup-image-1'},
          {'id': 'lineup-image-2'},
        ],
      },
      sortIndex: 0,
    );
    final mediaStore = MemoryDurableCloudMediaOutboxStore();
    await mediaStore.putAll([
      for (final assetId in ['lineup-image-1', 'lineup-image-2'])
        CloudMediaUploadJob(
          jobId: assetId,
          strategyPublicId: 'strategy-a',
          assetPublicId: assetId,
          fileExtension: '.png',
          mimeType: 'image/png',
          state: CloudMediaJobState.pendingUpload,
          referenceDurable: false,
          attempts: 0,
          updatedAt: DateTime.utc(2026, 9, 3),
        ),
    ]);
    final strategyStore = MemoryDurableStrategyOutboxStore();
    await strategyStore.put(_durableRecord(lineupOp));
    final container = _container(
      mediaStore,
      strategyStore: strategyStore,
      strategyOpen: false,
    );
    addTearDown(container.dispose);

    await container
        .read(cloudMediaUploadQueueProvider.notifier)
        .retryNow(ignoreBackoff: true);

    expect(container.read(strategyProvider).isOpen, isFalse);
    expect(
      container
          .read(cloudMediaUploadQueueProvider)
          .jobs
          .map((job) => job.referenceDurable),
      everyElement(isTrue),
    );
  });

  test('restart recovers when the strategy op was acked before promotion',
      () async {
    final mediaStore = MemoryDurableCloudMediaOutboxStore();
    await mediaStore.put(
      CloudMediaUploadJob(
        jobId: 'acked-image',
        strategyPublicId: 'strategy-a',
        assetPublicId: 'acked-image',
        fileExtension: '.png',
        mimeType: 'image/png',
        state: CloudMediaJobState.pendingUpload,
        referenceDurable: false,
        attempts: 0,
        updatedAt: DateTime.utc(2026, 9, 3),
      ),
    );
    var snapshotReads = 0;
    final snapshot = _fullSnapshot(
      elements: [
        RemoteElement(
          publicId: 'acked-image',
          strategyPublicId: 'strategy-a',
          pagePublicId: 'page-a',
          elementType: 'image',
          payload: cloudElementPayload(
            kind: 'image',
            data: const {'id': 'acked-image', 'elementType': 'image'},
          ),
          sortIndex: 0,
          revision: 1,
          deleted: false,
        ),
      ],
    );
    final container = _container(
      mediaStore,
      strategyStore: MemoryDurableStrategyOutboxStore(),
      strategyOpen: false,
      cloudReady: true,
      referenceSnapshotLoader: (strategyId) async {
        snapshotReads += 1;
        expect(strategyId, 'strategy-a');
        return snapshot;
      },
    );
    addTearDown(container.dispose);

    await container
        .read(cloudMediaUploadQueueProvider.notifier)
        .retryNow(ignoreBackoff: true);

    expect(snapshotReads, greaterThanOrEqualTo(1));
    expect(container.read(strategyProvider).isOpen, isFalse);
    expect(
      container
          .read(cloudMediaUploadQueueProvider)
          .jobs
          .single
          .referenceDurable,
      isTrue,
    );
  });

  test('restart removes only an unreferenced staged job, not its source',
      () async {
    const assetId = 'orphan-image';
    final source = await PlacedImageProvider.getImageFile(
      strategyID: 'strategy-a',
      imageID: assetId,
      fileExtension: '.png',
    );
    await source.writeAsBytes([1, 2, 3]);
    addTearDown(() async {
      if (await source.exists()) await source.delete();
    });
    final mediaStore = MemoryDurableCloudMediaOutboxStore();
    await mediaStore.put(
      CloudMediaUploadJob(
        jobId: assetId,
        strategyPublicId: 'strategy-a',
        assetPublicId: assetId,
        fileExtension: '.png',
        mimeType: 'image/png',
        state: CloudMediaJobState.pendingUpload,
        referenceDurable: false,
        attempts: 0,
        updatedAt: DateTime.utc(2026, 9, 3),
      ),
    );
    final container = _container(
      mediaStore,
      strategyStore: MemoryDurableStrategyOutboxStore(),
      strategyOpen: false,
      cloudReady: true,
      referenceSnapshotLoader: (_) async => _fullSnapshot(),
    );
    addTearDown(container.dispose);

    await container
        .read(cloudMediaUploadQueueProvider.notifier)
        .retryNow(ignoreBackoff: true);

    expect(container.read(cloudMediaUploadQueueProvider).jobs, isEmpty);
    expect(mediaStore.values, isEmpty);
    expect(await source.exists(), isTrue);
  });

  test('a newly staged job is not pruned before its mutation is admitted',
      () async {
    final mediaStore = MemoryDurableCloudMediaOutboxStore();
    final container = _container(
      mediaStore,
      strategyStore: MemoryDurableStrategyOutboxStore(),
      cloudReady: true,
      referenceSnapshotLoader: (_) async => _fullSnapshot(),
    );
    addTearDown(container.dispose);
    final queue = container.read(cloudMediaUploadQueueProvider.notifier);

    await queue.enqueuePlacedImageUpload(
      strategyPublicId: 'strategy-a',
      imagePublicId: 'new-image',
      fileExtension: '.png',
    );
    await queue.retryNow(ignoreBackoff: true);

    final job = container.read(cloudMediaUploadQueueProvider).jobs.single;
    expect(job.assetPublicId, 'new-image');
    expect(job.referenceDurable, isFalse);
    expect(mediaStore.values, contains('new-image'));
  });

  test('restart preserves an uploaded object that still needs attachment',
      () async {
    final store = MemoryDurableCloudMediaOutboxStore();
    await store.put(
      CloudMediaUploadJob(
        jobId: 'pending-attach-image',
        strategyPublicId: 'strategy-a',
        assetPublicId: 'pending-attach-image',
        fileExtension: '.png',
        mimeType: 'image/png',
        provider: 'r2',
        uploadId: 'upload-a',
        objectKey: 'strategies/strategy-a/images/pending-attach-image.png',
        etag: 'etag-a',
        byteSize: 1024,
        state: CloudMediaJobState.pendingAttach,
        attempts: 0,
        updatedAt: DateTime.utc(2026, 9, 3),
      ),
    );

    final restarted = _container(store);
    addTearDown(restarted.dispose);
    final job = restarted.read(cloudMediaUploadQueueProvider).jobs.single;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(job.state, CloudMediaJobState.pendingAttach);
    expect(job.uploadId, 'upload-a');
    expect(job.objectKey, contains('pending-attach-image.png'));
    expect(job.etag, 'etag-a');
  });

  test('media from another strategy does not affect the active save state', () {
    final mediaQueue = _MutableMediaQueue();
    final container = ProviderContainer(
      overrides: [
        strategyProvider.overrideWith(_ActiveCloudStrategy.new),
        strategyOpQueueProvider.overrideWith(_SettledOpQueue.new),
        cloudMediaUploadQueueProvider.overrideWith(() => mediaQueue),
      ],
    );
    addTearDown(container.dispose);
    container.read(strategySaveStateProvider);

    mediaQueue.replaceJobs([
      CloudMediaUploadJob(
        jobId: 'other-image',
        strategyPublicId: 'strategy-b',
        assetPublicId: 'other-image',
        fileExtension: '.png',
        mimeType: 'image/png',
        state: CloudMediaJobState.failed,
        attempts: 1,
        lastError: 'Local media file is missing.',
        updatedAt: DateTime.utc(2026, 9, 3),
      ),
    ]);

    final saveState = container.read(strategySaveStateProvider);
    expect(saveState.hasPendingMediaSync, isFalse);
    expect(saveState.mediaSyncErrorCount, 0);
    expect(saveState.isDirty, isFalse);
  });
}
