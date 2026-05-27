import 'dart:async';
import 'dart:developer';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';

final remoteStrategySnapshotProvider = AsyncNotifierProvider<
    RemoteStrategySnapshotNotifier, RemoteStrategySnapshot?>(
  RemoteStrategySnapshotNotifier.new,
);

class RemoteStrategySnapshotNotifier
    extends AsyncNotifier<RemoteStrategySnapshot?> {
  String? _activeStrategyPublicId;
  StreamSubscription<RemoteStrategyHeader>? _headerSubscription;
  StreamSubscription<List<RemotePage>>? _pagesSubscription;
  StreamSubscription<List<RemoteImageAsset>>? _assetsSubscription;
  StreamSubscription<List<RemoteElement>>? _elementsSubscription;
  StreamSubscription<List<RemoteLineup>>? _lineupsSubscription;
  Timer? _refreshDebounce;

  @override
  Future<RemoteStrategySnapshot?> build() async {
    ref.onDispose(_disposeSubscriptions);
    return null;
  }

  String? get activeStrategyPublicId => _activeStrategyPublicId;

  Future<void> openStrategy(String strategyPublicId) async {
    _activeStrategyPublicId = strategyPublicId;
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

    _headerSubscription = repository
        .watchStrategyHeader(strategyPublicId)
        .listen(
          (header) =>
              _replaceSnapshot((snapshot) => snapshot.replaceHeader(header)),
          onError: (error, stackTrace) => _handleSubscriptionError(
            source: 'remote_snapshot:header_subscription',
            error: error,
            stackTrace: stackTrace,
          ),
        );

    _pagesSubscription =
        repository.watchPagesForStrategy(strategyPublicId).listen(
              (pages) =>
                  _replaceSnapshot((snapshot) => snapshot.replacePages(pages)),
              onError: (error, stackTrace) => _handleSubscriptionError(
                source: 'remote_snapshot:pages_subscription',
                error: error,
                stackTrace: stackTrace,
              ),
            );

    _assetsSubscription =
        repository.watchImageAssetsForStrategy(strategyPublicId).listen(
              (assets) => _replaceSnapshot(
                (snapshot) => snapshot.replaceAssets(assets),
              ),
              onError: (error, stackTrace) => _handleSubscriptionError(
                source: 'remote_snapshot:assets_subscription',
                error: error,
                stackTrace: stackTrace,
              ),
            );

    _elementsSubscription =
        repository.watchElementsForStrategy(strategyPublicId).listen(
              (elements) => _replaceSnapshot(
                (snapshot) => snapshot.replaceElements(elements),
              ),
              onError: (error, stackTrace) => _handleSubscriptionError(
                source: 'remote_snapshot:elements_subscription',
                error: error,
                stackTrace: stackTrace,
              ),
            );

    _lineupsSubscription =
        repository.watchLineupsForStrategy(strategyPublicId).listen(
              (lineups) => _replaceSnapshot(
                (snapshot) => snapshot.replaceLineups(lineups),
              ),
              onError: (error, stackTrace) => _handleSubscriptionError(
                source: 'remote_snapshot:lineups_subscription',
                error: error,
                stackTrace: stackTrace,
              ),
            );
  }

  void _replaceSnapshot(
    RemoteStrategySnapshot Function(RemoteStrategySnapshot snapshot) replace,
  ) {
    if (_activeStrategyPublicId == null) {
      return;
    }
    if (ref.read(authProvider).hasActiveAuthIncident) {
      return;
    }

    final current = state.valueOrNull;
    if (current == null) {
      _scheduleRefresh();
      return;
    }
    state = AsyncData(replace(current));
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

    unawaited(_headerSubscription?.cancel());
    _headerSubscription = null;

    unawaited(_pagesSubscription?.cancel());
    _pagesSubscription = null;

    unawaited(_assetsSubscription?.cancel());
    _assetsSubscription = null;

    unawaited(_elementsSubscription?.cancel());
    _elementsSubscription = null;

    unawaited(_lineupsSubscription?.cancel());
    _lineupsSubscription = null;
  }
}
