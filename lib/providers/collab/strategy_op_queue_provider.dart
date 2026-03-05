import 'dart:async';
import 'dart:developer';
import 'dart:math' as math;

import 'package:convex_flutter/convex_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:uuid/uuid.dart';

class StrategyOpQueueState {
  const StrategyOpQueueState({
    this.strategyPublicId,
    this.clientId,
    this.pending = const <PendingOp>[],
    this.isFlushing = false,
    this.lastError,
    this.lastFlushAt,
    this.lastAcks = const <OpAck>[],
  });

  final String? strategyPublicId;
  final String? clientId;
  final List<PendingOp> pending;
  final bool isFlushing;
  final String? lastError;
  final DateTime? lastFlushAt;
  final List<OpAck> lastAcks;

  StrategyOpQueueState copyWith({
    String? strategyPublicId,
    String? clientId,
    List<PendingOp>? pending,
    bool? isFlushing,
    String? lastError,
    bool clearError = false,
    DateTime? lastFlushAt,
    List<OpAck>? lastAcks,
  }) {
    return StrategyOpQueueState(
      strategyPublicId: strategyPublicId ?? this.strategyPublicId,
      clientId: clientId ?? this.clientId,
      pending: pending ?? this.pending,
      isFlushing: isFlushing ?? this.isFlushing,
      lastError: clearError ? null : (lastError ?? this.lastError),
      lastFlushAt: lastFlushAt ?? this.lastFlushAt,
      lastAcks: lastAcks ?? this.lastAcks,
    );
  }
}

final strategyOpQueueProvider =
    NotifierProvider<StrategyOpQueueNotifier, StrategyOpQueueState>(
  StrategyOpQueueNotifier.new,
);

final pendingStrategyOpsProvider = Provider<List<StrategyOp>>((ref) {
  return ref.watch(strategyOpQueueProvider).pending.map((op) => op.op).toList();
});

class StrategyOpQueueNotifier extends Notifier<StrategyOpQueueState> {
  static const int _maxBatchSize = 40;
  static const Duration _debounceDelay = Duration(milliseconds: 180);
  Timer? _debounceTimer;

  ConvexStrategyRepository get _repo =>
      ref.read(convexStrategyRepositoryProvider);

  @override
  StrategyOpQueueState build() {
    ref.onDispose(() {
      _debounceTimer?.cancel();
    });
    return StrategyOpQueueState(clientId: const Uuid().v4());
  }

  void setActiveStrategy(String? strategyPublicId) {
    if (state.strategyPublicId == strategyPublicId) return;

    _debounceTimer?.cancel();
    state = state.copyWith(
      strategyPublicId: strategyPublicId,
      clientId: const Uuid().v4(),
      pending: const [],
      lastAcks: const [],
      clearError: true,
    );
  }

  void enqueue(StrategyOp op, {bool flushImmediately = false}) {
    final currentStrategyId = state.strategyPublicId;
    if (currentStrategyId == null) {
      return;
    }

    final byOpId = <String, PendingOp>{
      for (final existing in state.pending) existing.op.opId: existing,
    };

    byOpId[op.opId] = PendingOp(
      op: op,
      clientId: state.clientId ?? const Uuid().v4(),
      attempts: 0,
    );

    state = state.copyWith(
      pending: byOpId.values.toList(growable: false),
      clearError: true,
    );

    if (flushImmediately) {
      unawaited(flushNow());
      return;
    }

    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDelay, () {
      unawaited(flushNow());
    });
  }

  void enqueueAll(Iterable<StrategyOp> ops, {bool flushImmediately = false}) {
    for (final op in ops) {
      enqueue(op, flushImmediately: false);
    }
    if (flushImmediately) {
      unawaited(flushNow());
    }
  }

  Future<void> flushNow() async {
    if (state.isFlushing) {
      return;
    }

    final strategyPublicId = state.strategyPublicId;
    if (strategyPublicId == null || state.pending.isEmpty) {
      return;
    }

    final auth = ref.read(authProvider);
    final mode = ref.read(cloudCollabModeProvider);
    final isConnected = ConvexClient.instance.isConnected;

    if (!mode.featureFlagEnabled || mode.forceLocalFallback) {
      return;
    }

    if (auth.hasActiveAuthIncident) {
      state = state.copyWith(
        lastError: 'Cloud auth incident active. Awaiting user action.',
      );
      return;
    }

    if (!auth.isAuthenticated || !auth.isConvexUserReady || !isConnected) {
      final incremented = [
        for (final pending in state.pending) pending.incrementAttempt(),
      ];
      state = state.copyWith(
        pending: incremented,
        lastError: !auth.isAuthenticated
            ? 'Not authenticated for cloud sync.'
            : (!auth.isConvexUserReady
                ? 'Cloud user setup is not ready.'
                : 'Cloud connection is offline.'),
      );
      _scheduleRetry(incremented);
      return;
    }

    state = state.copyWith(isFlushing: true, clearError: true);

    final batch = state.pending.take(_maxBatchSize).toList(growable: false);
    final ops = batch.map((pending) => pending.op).toList(growable: false);

    try {
      final acks = await _repo.applyBatch(
        strategyPublicId: strategyPublicId,
        clientId: state.clientId ?? const Uuid().v4(),
        ops: ops,
      );

      final rejected = <String, PendingOp>{};
      for (final pending in batch) {
        rejected[pending.op.opId] = pending;
      }

      for (final ack in acks) {
        if (ack.isAck) {
          rejected.remove(ack.opId);
          continue;
        }

        final pending = rejected[ack.opId];
        if (pending != null) {
          rejected[ack.opId] = pending.incrementAttempt();
        }
      }

      final untouched = state.pending.skip(batch.length).toList(growable: false);
      final retried = rejected.values.toList(growable: false);
      state = state.copyWith(
        pending: [...retried, ...untouched],
        isFlushing: false,
        lastFlushAt: DateTime.now(),
        lastAcks: acks,
      );

      if (rejected.isNotEmpty) {
        _scheduleRetry(retried);
      } else if (untouched.isNotEmpty) {
        unawaited(flushNow());
      }
    } catch (error, stackTrace) {
      if (isConvexUnauthenticatedError(error)) {
        unawaited(
          ref.read(authProvider.notifier).reportConvexUnauthenticated(
                source: 'strategy_op_queue:flush',
                error: error,
                stackTrace: stackTrace,
              ),
        );
        state = state.copyWith(
          isFlushing: false,
          lastError: 'Cloud authentication expired. Retry required.',
        );
        return;
      }

      log('Failed flushing op queue: $error',
          error: error, stackTrace: stackTrace);

      final incremented = [
        for (final pending in state.pending) pending.incrementAttempt(),
      ];

      state = state.copyWith(
        pending: incremented,
        isFlushing: false,
        lastError: '$error',
      );

      _scheduleRetry(incremented);
    }
  }

  void _scheduleRetry(List<PendingOp> pending) {
    if (pending.isEmpty) return;

    final maxAttempt = pending.fold<int>(
      0,
      (acc, next) => math.max(acc, next.attempts),
    );
    final exponent = maxAttempt.clamp(0, 6);
    final delayMs = 300 * (1 << exponent);

    _debounceTimer?.cancel();
    _debounceTimer = Timer(Duration(milliseconds: delayMs), () {
      unawaited(flushNow());
    });
  }
}
