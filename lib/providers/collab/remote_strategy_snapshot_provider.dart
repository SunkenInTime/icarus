import 'dart:async';
import 'dart:developer';

import 'package:convex_flutter/convex_flutter.dart';
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
  dynamic _headerSubscription;
  dynamic _pagesSubscription;
  final Map<String, dynamic> _elementSubscriptions = {};
  final Map<String, dynamic> _lineupSubscriptions = {};
  Timer? _refreshDebounce;

  @override
  Future<RemoteStrategySnapshot?> build() async {
    ref.onDispose(_disposeSubscriptions);
    return null;
  }

  String? get activeStrategyPublicId => _activeStrategyPublicId;

  Future<void> openStrategy(String strategyPublicId) async {
    _activeStrategyPublicId = strategyPublicId;
    ref.read(strategyOpQueueProvider.notifier).setActiveStrategy(strategyPublicId);
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
      await _syncPageSubscriptions(snapshot);
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

    _headerSubscription = await ConvexClient.instance.subscribe(
      name: 'strategies:getHeader',
      args: {'strategyPublicId': strategyPublicId},
      onUpdate: (_) => _scheduleRefresh(),
      onError: (message, _) => _handleSubscriptionError(
        source: 'remote_snapshot:header_subscription',
        message: message,
      ),
    );

    _pagesSubscription = await ConvexClient.instance.subscribe(
      name: 'pages:listForStrategy',
      args: {'strategyPublicId': strategyPublicId},
      onUpdate: (value) {
        final pageIds = ((value as List?) ?? const [])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .map((item) => item['publicId'] as String?)
            .whereType<String>()
            .toSet();

        _syncPageWatchersFromIds(strategyPublicId, pageIds);
        _scheduleRefresh();
      },
      onError: (message, _) => _handleSubscriptionError(
        source: 'remote_snapshot:pages_subscription',
        message: message,
      ),
    );
  }

  Future<void> _syncPageSubscriptions(RemoteStrategySnapshot snapshot) async {
    final strategyPublicId = _activeStrategyPublicId;
    if (strategyPublicId == null) {
      return;
    }

    final pageIds = snapshot.pages.map((page) => page.publicId).toSet();
    _syncPageWatchersFromIds(strategyPublicId, pageIds);
  }

  void _syncPageWatchersFromIds(
    String strategyPublicId,
    Set<String> pageIds,
  ) {
    final existingElementPageIds = _elementSubscriptions.keys.toSet();
    final existingLineupPageIds = _lineupSubscriptions.keys.toSet();

    for (final pageId in existingElementPageIds.difference(pageIds)) {
      _cancelSubscription(_elementSubscriptions.remove(pageId));
    }
    for (final pageId in existingLineupPageIds.difference(pageIds)) {
      _cancelSubscription(_lineupSubscriptions.remove(pageId));
    }

    for (final pageId in pageIds) {
      if (!_elementSubscriptions.containsKey(pageId)) {
        _elementSubscriptions[pageId] = true;
        ConvexClient.instance
            .subscribe(
          name: 'elements:listForPage',
          args: {
            'strategyPublicId': strategyPublicId,
            'pagePublicId': pageId,
          },
          onUpdate: (_) => _scheduleRefresh(),
          onError: (message, _) => _handleSubscriptionError(
            source: 'remote_snapshot:elements_subscription',
            message: message,
          ),
        )
            .then((subscription) {
          final current = _elementSubscriptions[pageId];
          if (current == null) {
            _cancelSubscription(subscription);
            return;
          }
          _elementSubscriptions[pageId] = subscription;
        });
      }

      if (!_lineupSubscriptions.containsKey(pageId)) {
        _lineupSubscriptions[pageId] = true;
        ConvexClient.instance
            .subscribe(
          name: 'lineups:listForPage',
          args: {
            'strategyPublicId': strategyPublicId,
            'pagePublicId': pageId,
          },
          onUpdate: (_) => _scheduleRefresh(),
          onError: (message, _) => _handleSubscriptionError(
            source: 'remote_snapshot:lineups_subscription',
            message: message,
          ),
        )
            .then((subscription) {
          final current = _lineupSubscriptions[pageId];
          if (current == null) {
            _cancelSubscription(subscription);
            return;
          }
          _lineupSubscriptions[pageId] = subscription;
        });
      }
    }
  }

  void _handleSubscriptionError({
    required String source,
    required String message,
  }) {
    if (isConvexUnauthenticatedMessage(message)) {
      unawaited(
        ref.read(authProvider.notifier).reportConvexUnauthenticated(
              source: source,
              error: Exception(message),
            ),
      );
      return;
    }

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

    _cancelSubscription(_headerSubscription);
    _headerSubscription = null;

    _cancelSubscription(_pagesSubscription);
    _pagesSubscription = null;

    for (final subscription in _elementSubscriptions.values) {
      _cancelSubscription(subscription);
    }
    _elementSubscriptions.clear();

    for (final subscription in _lineupSubscriptions.values) {
      _cancelSubscription(subscription);
    }
    _lineupSubscriptions.clear();
  }

  void _cancelSubscription(dynamic subscription) {
    try {
      subscription?.cancel();
    } catch (_) {
      // Best-effort cleanup.
    }
  }
}
