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

    final incoming = PendingOp(
      op: op,
      clientId: state.clientId ?? const Uuid().v4(),
      attempts: 0,
    );
    final mergedPending = _mergePending(state.pending, incoming);

    state = state.copyWith(
      pending: mergedPending,
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

  List<PendingOp> _mergePending(List<PendingOp> pending, PendingOp incoming) {
    final entityKey = _entityKeyForOp(incoming.op);
    if (entityKey == null) {
      return [...pending, incoming];
    }

    final merged = <PendingOp>[];
    var handled = false;

    for (final existing in pending) {
      if (handled || _entityKeyForOp(existing.op) != entityKey) {
        merged.add(existing);
        continue;
      }

      final replacement = _mergePendingOp(existing, incoming);
      if (replacement != null) {
        merged.add(replacement);
      }
      handled = true;
    }

    if (!handled) {
      merged.add(incoming);
    }

    return merged;
  }

  String? _entityKeyForOp(StrategyOp op) {
    switch (op.entityType) {
      case StrategyOpEntityType.strategy:
        return 'strategy';
      case StrategyOpEntityType.page:
        return op.entityPublicId == null ? null : 'page:${op.entityPublicId}';
      case StrategyOpEntityType.element:
        if (op.pagePublicId == null || op.entityPublicId == null) {
          return null;
        }
        return 'element:${op.pagePublicId}:${op.entityPublicId}';
      case StrategyOpEntityType.lineup:
        if (op.pagePublicId == null || op.entityPublicId == null) {
          return null;
        }
        return 'lineup:${op.pagePublicId}:${op.entityPublicId}';
    }
  }

  PendingOp? _mergePendingOp(PendingOp existing, PendingOp incoming) {
    final existingOp = existing.op;
    final incomingOp = incoming.op;

    if (incomingOp.kind == StrategyOpKind.delete &&
        existingOp.kind == StrategyOpKind.add) {
      return null;
    }

    if (existingOp.kind == StrategyOpKind.add &&
        incomingOp.kind == StrategyOpKind.patch) {
      return PendingOp(
        op: StrategyOp(
          opId: existingOp.opId,
          kind: StrategyOpKind.add,
          entityType: existingOp.entityType,
          entityPublicId: existingOp.entityPublicId,
          pagePublicId: existingOp.pagePublicId,
          payload: incomingOp.payload ?? existingOp.payload,
          sortIndex: incomingOp.sortIndex ?? existingOp.sortIndex,
          expectedRevision: existingOp.expectedRevision,
          expectedSequence: existingOp.expectedSequence,
        ),
        clientId: existing.clientId,
        attempts: existing.attempts,
        lastAttemptAt: existing.lastAttemptAt,
      );
    }

    return PendingOp(
      op: StrategyOp(
        opId: existingOp.opId,
        kind: incomingOp.kind,
        entityType: incomingOp.entityType,
        entityPublicId: incomingOp.entityPublicId ?? existingOp.entityPublicId,
        pagePublicId: incomingOp.pagePublicId ?? existingOp.pagePublicId,
        payload: incomingOp.payload ?? existingOp.payload,
        sortIndex: incomingOp.sortIndex ?? existingOp.sortIndex,
        expectedRevision: incomingOp.expectedRevision ?? existingOp.expectedRevision,
        expectedSequence: incomingOp.expectedSequence ?? existingOp.expectedSequence,
      ),
      clientId: existing.clientId,
      attempts: existing.attempts,
      lastAttemptAt: existing.lastAttemptAt,
    );
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
