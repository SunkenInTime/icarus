import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/durable_cloud_media_outbox.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
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

ProviderContainer _container(MemoryDurableCloudMediaOutboxStore store) {
  return ProviderContainer(
    overrides: [
      durableCloudMediaOutboxStoreProvider.overrideWithValue(store),
      authProvider.overrideWith(_SignedOutAuthProvider.new),
      cloudCollabModeProvider.overrideWith(_DisabledCloudCollabMode.new),
      convexConnectionProvider.overrideWith((ref) => Stream.value(false)),
    ],
  );
}

void main() {
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
    first.dispose();

    final restarted = _container(store);
    addTearDown(restarted.dispose);
    final restored = restarted
        .read(cloudMediaUploadQueueProvider)
        .jobsForStrategy('strategy-a');

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
