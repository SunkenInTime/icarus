import 'dart:async';
import 'dart:developer';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/image_provider.dart';

final remoteStrategySnapshotProvider = AsyncNotifierProvider<
    RemoteStrategySnapshotNotifier, RemoteStrategySnapshot?>(
  RemoteStrategySnapshotNotifier.new,
);

class RemoteStrategySnapshotNotifier
    extends AsyncNotifier<RemoteStrategySnapshot?> {
  String? _activeStrategyPublicId;
  StreamSubscription<RemoteStrategySnapshot>? _snapshotSubscription;
  Timer? _refreshDebounce;
  Map<String, RemoteImageAsset>? _lastReconciledAssetsById;

  @override
  Future<RemoteStrategySnapshot?> build() async {
    ref.onDispose(_disposeSubscriptions);
    return null;
  }

  String? get activeStrategyPublicId => _activeStrategyPublicId;

  Future<void> openStrategy(String strategyPublicId) async {
    _activeStrategyPublicId = strategyPublicId;
    _lastReconciledAssetsById = null;
    ref
        .read(strategyOpQueueProvider.notifier)
        .setActiveStrategy(strategyPublicId);
    state = const AsyncLoading();

    await _refreshFromServer();
    await _startSubscriptions(strategyPublicId);
  }

  Future<void> refresh() async {
    if (_activeStrategyPublicId == null) {
      return;
    }
    await _refreshFromServer();
  }

  void clear() {
    _activeStrategyPublicId = null;
    _lastReconciledAssetsById = null;
    _disposeSubscriptions();
    ref.read(strategyOpQueueProvider.notifier).setActiveStrategy(null);
    state = const AsyncData(null);
  }

  Future<void> _refreshFromServer() async {
    final strategyPublicId = _activeStrategyPublicId;
    if (strategyPublicId == null) {
      return;
    }

    final auth = ref.read(authProvider);
    if (auth.hasActiveAuthIncident) {
      state = const AsyncData(null);
      return;
    }

    try {
      final snapshot = await ref
          .read(convexStrategyRepositoryProvider)
          .fetchSnapshot(strategyPublicId);
      state = AsyncData(snapshot);
    } catch (error, stackTrace) {
      if (isConvexUnauthenticatedError(error)) {
        unawaited(
          ref.read(authProvider.notifier).reportConvexUnauthenticated(
                source: 'remote_snapshot:refresh',
                error: error,
                stackTrace: stackTrace,
              ),
        );
        state = const AsyncData(null);
        return;
      }

      log('Failed to refresh remote snapshot: $error',
          error: error, stackTrace: stackTrace);
      state = AsyncError(error, stackTrace);
    }
  }

  Future<void> _startSubscriptions(String strategyPublicId) async {
    _disposeSubscriptions();
    final repository = ref.read(convexStrategyRepositoryProvider);

    _snapshotSubscription = repository.watchSnapshot(strategyPublicId).listen(
      (snapshot) {
        _replaceSnapshot(snapshot);
        if (_shouldReconcilePageMedia(snapshot.assetsById)) {
          unawaited(
            ref.read(cloudMediaUploadQueueProvider.notifier).reconcilePageMedia(
                  strategyPublicId: strategyPublicId,
                  placedImages: ref.read(placedImageProvider).images,
                  assetsById: snapshot.assetsById,
                ),
          );
        }
      },
      onError: (error, stackTrace) => _handleSubscriptionError(
        source: 'remote_snapshot:snapshot_subscription',
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }

  void _replaceSnapshot(RemoteStrategySnapshot snapshot) {
    if (_activeStrategyPublicId == null) {
      return;
    }
    if (ref.read(authProvider).hasActiveAuthIncident) {
      return;
    }

    state = AsyncData(snapshot);
  }

  bool _shouldReconcilePageMedia(
    Map<String, RemoteImageAsset> nextAssetsById,
  ) {
    final previous = _lastReconciledAssetsById;
    if (previous != null && _sameReconcileAssetSet(previous, nextAssetsById)) {
      return false;
    }

    _lastReconciledAssetsById =
        Map<String, RemoteImageAsset>.unmodifiable(nextAssetsById);
    return true;
  }

  bool _sameReconcileAssetSet(
    Map<String, RemoteImageAsset> previous,
    Map<String, RemoteImageAsset> next,
  ) {
    if (previous.length != next.length) {
      return false;
    }

    for (final entry in next.entries) {
      final previousAsset = previous[entry.key];
      final nextAsset = entry.value;
      if (previousAsset == null ||
          previousAsset.publicId != nextAsset.publicId ||
          previousAsset.url != nextAsset.url ||
          previousAsset.uploadStatus != nextAsset.uploadStatus) {
        return false;
      }
    }
    return true;
  }

  void _handleSubscriptionError({
    required String source,
    required Object error,
    StackTrace? stackTrace,
  }) {
    final message = error.toString();
    if (isConvexUnauthenticatedMessage(message)) {
      unawaited(
        ref.read(authProvider.notifier).reportConvexUnauthenticated(
              source: source,
              error: error,
              stackTrace: stackTrace,
            ),
      );
      return;
    }

    log(
      'Remote snapshot subscription failed: $message',
      name: 'remote_snapshot',
      error: error,
      stackTrace: stackTrace,
    );
    _scheduleRefresh();
  }

  void _scheduleRefresh() {
    if (_activeStrategyPublicId == null) {
      return;
    }

    if (ref.read(authProvider).hasActiveAuthIncident) {
      return;
    }

    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 120), () async {
      await _refreshFromServer();
    });
  }

  void _disposeSubscriptions() {
    _refreshDebounce?.cancel();
    _refreshDebounce = null;

    unawaited(_snapshotSubscription?.cancel());
    _snapshotSubscription = null;
  }
}
