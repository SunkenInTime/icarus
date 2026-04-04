import 'dart:async';
import 'dart:developer';
import 'dart:math' as math;

import 'package:convex_flutter/convex_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:uuid/uuid.dart';

class StrategyOpQueueState {
  const StrategyOpQueueState({
    this.strategyPublicId,
    this.clientId,
    this.queuedByEntityKey = const <EntitySyncKey, QueuedEntityIntent>{},
    this.inFlightByEntityKey = const <EntitySyncKey, InFlightEntityIntent>{},
    this.isFlushing = false,
    this.lastError,
    this.lastFlushAt,
    this.lastAcks = const <OpAck>[],
    this.lastAckBatch = const <AckedEntityIntent>[],
  });

  final String? strategyPublicId;
  final String? clientId;
  final Map<EntitySyncKey, QueuedEntityIntent> queuedByEntityKey;
  final Map<EntitySyncKey, InFlightEntityIntent> inFlightByEntityKey;
  final bool isFlushing;
  final String? lastError;
  final DateTime? lastFlushAt;
  final List<OpAck> lastAcks;
  final List<AckedEntityIntent> lastAckBatch;

  List<PendingOp> get pending => [
        ...queuedByEntityKey.values.map((intent) => intent.pending),
        ...inFlightByEntityKey.values.map((intent) => intent.pending),
      ];

  StrategyOpQueueState copyWith({
    String? strategyPublicId,
    String? clientId,
    Map<EntitySyncKey, QueuedEntityIntent>? queuedByEntityKey,
    Map<EntitySyncKey, InFlightEntityIntent>? inFlightByEntityKey,
    bool? isFlushing,
    String? lastError,
    bool clearError = false,
    DateTime? lastFlushAt,
    List<OpAck>? lastAcks,
    List<AckedEntityIntent>? lastAckBatch,
  }) {
    return StrategyOpQueueState(
      strategyPublicId: strategyPublicId ?? this.strategyPublicId,
      clientId: clientId ?? this.clientId,
      queuedByEntityKey: queuedByEntityKey ?? this.queuedByEntityKey,
      inFlightByEntityKey: inFlightByEntityKey ?? this.inFlightByEntityKey,
      isFlushing: isFlushing ?? this.isFlushing,
      lastError: clearError ? null : (lastError ?? this.lastError),
      lastFlushAt: lastFlushAt ?? this.lastFlushAt,
      lastAcks: lastAcks ?? this.lastAcks,
      lastAckBatch: lastAckBatch ?? this.lastAckBatch,
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
    if (state.strategyPublicId == strategyPublicId) {
      return;
    }

    _debounceTimer?.cancel();
    state = state.copyWith(
      strategyPublicId: strategyPublicId,
      clientId: const Uuid().v4(),
      queuedByEntityKey: const <EntitySyncKey, QueuedEntityIntent>{},
      inFlightByEntityKey: const <EntitySyncKey, InFlightEntityIntent>{},
      lastAcks: const <OpAck>[],
      lastAckBatch: const <AckedEntityIntent>[],
      clearError: true,
    );
  }

  void enqueue(StrategyOp op, {bool flushImmediately = false}) {
    final entityKey = entityKeyForStrategyOp(op);
    if (entityKey == null) {
      return;
    }
    final pageId = pageIdForEntityKey(entityKey);
    if (pageId != null) {
      syncDesiredOpsForPage(
        pageId: pageId,
        desiredOpsByEntityKey: {entityKey: op},
        clearMissing: false,
        flushImmediately: flushImmediately,
      );
      return;
    }

    final queued = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.queuedByEntityKey,
    );
    queued[entityKey] = QueuedEntityIntent(
      entityKey: entityKey,
      pending: PendingOp(
        op: op,
        clientId: state.clientId ?? const Uuid().v4(),
      ),
    );
    state = state.copyWith(
      queuedByEntityKey: queued,
      clearError: true,
    );
    _scheduleFlush(flushImmediately: flushImmediately);
  }

  void enqueueAll(Iterable<StrategyOp> ops, {bool flushImmediately = false}) {
    final opsByPage = <String, Map<EntitySyncKey, StrategyOp>>{};
    final genericQueued = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.queuedByEntityKey,
    );

    for (final op in ops) {
      final entityKey = entityKeyForStrategyOp(op);
      if (entityKey == null) {
        continue;
      }
      final pageId = pageIdForEntityKey(entityKey);
      if (pageId == null) {
        genericQueued[entityKey] = QueuedEntityIntent(
          entityKey: entityKey,
          pending: PendingOp(
            op: op,
            clientId: state.clientId ?? const Uuid().v4(),
          ),
        );
        continue;
      }
      opsByPage.putIfAbsent(pageId, () => <EntitySyncKey, StrategyOp>{})[entityKey] =
          op;
    }

    if (!mapEquals(genericQueued, state.queuedByEntityKey)) {
      state = state.copyWith(
        queuedByEntityKey: genericQueued,
        clearError: true,
      );
    }

    for (final entry in opsByPage.entries) {
      syncDesiredOpsForPage(
        pageId: entry.key,
        desiredOpsByEntityKey: entry.value,
        clearMissing: false,
        flushImmediately: false,
      );
    }
    _scheduleFlush(flushImmediately: flushImmediately);
  }

  void syncDesiredOpsForPage({
    required String pageId,
    required Map<EntitySyncKey, StrategyOp> desiredOpsByEntityKey,
    bool clearMissing = true,
    bool flushImmediately = false,
  }) {
    final queued = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.queuedByEntityKey,
    );
    final pageKeys = clearMissing
        ? <EntitySyncKey>{
            ...queued.keys.where((key) => pageIdForEntityKey(key) == pageId),
            ...desiredOpsByEntityKey.keys,
          }
        : desiredOpsByEntityKey.keys.toSet();

    var changed = false;
    for (final key in pageKeys) {
      final desired = desiredOpsByEntityKey[key];
      final existingQueued = queued[key];
      final inFlight = state.inFlightByEntityKey[key]?.pending.op;

      if (desired == null) {
        if (queued.remove(key) != null) {
          changed = true;
          _debugLog('queued.drop $key reason=returned_to_remote_base');
        }
        continue;
      }

      if (inFlight != null && _sameIntent(desired, inFlight)) {
        if (queued.remove(key) != null) {
          changed = true;
          _debugLog('queued.drop $key reason=covered_by_in_flight');
        }
        continue;
      }

      if (existingQueued != null && _sameIntent(existingQueued.pending.op, desired)) {
        continue;
      }

      final mergedDesired = existingQueued == null
          ? desired
          : _mergeQueuedIntent(existingQueued.pending.op, desired);
      if (mergedDesired == null) {
        if (queued.remove(key) != null) {
          changed = true;
          _debugLog('queued.drop $key reason=coalesced_to_noop');
        }
        continue;
      }

      queued[key] = QueuedEntityIntent(
        entityKey: key,
        pending: PendingOp(
          op: mergedDesired,
          clientId: state.clientId ?? const Uuid().v4(),
          attempts: existingQueued?.pending.attempts ?? 0,
          lastAttemptAt: existingQueued?.pending.lastAttemptAt,
        ),
      );
      changed = true;
      _debugLog(
        existingQueued == null
            ? 'queued.upsert $key kind=${mergedDesired.kind.name}'
            : 'queued.replace $key kind=${mergedDesired.kind.name}',
      );
    }

    if (!changed) {
      return;
    }

    state = state.copyWith(
      queuedByEntityKey: queued,
      clearError: true,
    );
    _scheduleFlush(flushImmediately: flushImmediately);
  }

  Future<void> flushNow() async {
    if (state.isFlushing) {
      return;
    }

    final strategyPublicId = state.strategyPublicId;
    if (strategyPublicId == null || state.queuedByEntityKey.isEmpty) {
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
      final incremented = <EntitySyncKey, QueuedEntityIntent>{
        for (final entry in state.queuedByEntityKey.entries)
          entry.key: QueuedEntityIntent(
            entityKey: entry.key,
            pending: entry.value.pending.incrementAttempt(),
          ),
      };
      state = state.copyWith(
        queuedByEntityKey: incremented,
        lastError: !auth.isAuthenticated
            ? 'Not authenticated for cloud sync.'
            : (!auth.isConvexUserReady
                ? 'Cloud user setup is not ready.'
                : 'Cloud connection is offline.'),
      );
      _scheduleRetry(incremented.values.map((intent) => intent.pending).toList());
      return;
    }

    final batch = state.queuedByEntityKey.values
        .where((intent) => !state.inFlightByEntityKey.containsKey(intent.entityKey))
        .take(_maxBatchSize)
        .toList(growable: false);
    if (batch.isEmpty) {
      return;
    }

    final queued = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.queuedByEntityKey,
    );
    final inFlight = Map<EntitySyncKey, InFlightEntityIntent>.from(
      state.inFlightByEntityKey,
    );
    final sentAt = DateTime.now();
    final batchByOpId = <String, QueuedEntityIntent>{};
    for (final intent in batch) {
      queued.remove(intent.entityKey);
      inFlight[intent.entityKey] = InFlightEntityIntent(
        entityKey: intent.entityKey,
        pending: intent.pending,
        sentAt: sentAt,
      );
      batchByOpId[intent.pending.op.opId] = intent;
      _debugLog('inflight.send ${intent.entityKey} op=${intent.pending.op.opId}');
    }

    state = state.copyWith(
      queuedByEntityKey: queued,
      inFlightByEntityKey: inFlight,
      isFlushing: true,
      clearError: true,
    );

    try {
      final acks = await _repo.applyBatch(
        strategyPublicId: strategyPublicId,
        clientId: state.clientId ?? const Uuid().v4(),
        ops: batch.map((intent) => intent.pending.op).toList(growable: false),
      );

      final latestQueued = Map<EntitySyncKey, QueuedEntityIntent>.from(
        state.queuedByEntityKey,
      );
      final latestInFlight = Map<EntitySyncKey, InFlightEntityIntent>.from(
        state.inFlightByEntityKey,
      );
      final acked = <AckedEntityIntent>[];
      for (final ack in acks) {
        final sent = batchByOpId[ack.opId];
        if (sent == null) {
          continue;
        }
        latestInFlight.remove(sent.entityKey);
        acked.add(
          AckedEntityIntent(
            entityKey: sent.entityKey,
            op: sent.pending.op,
            ack: ack,
          ),
        );
        _debugLog(
          'inflight.${ack.isAck ? 'ack' : 'reject'} ${sent.entityKey} op=${ack.opId}',
        );
      }

      for (final sent in batch) {
        latestInFlight.remove(sent.entityKey);
      }

      state = state.copyWith(
        queuedByEntityKey: latestQueued,
        inFlightByEntityKey: latestInFlight,
        isFlushing: false,
        lastFlushAt: DateTime.now(),
        lastAcks: acks,
        lastAckBatch: acked,
      );

      if (state.queuedByEntityKey.isNotEmpty) {
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
        _restoreBatchAfterFailure(
          batch,
          lastError: 'Cloud authentication expired. Retry required.',
        );
        return;
      }

      log(
        'Failed flushing op queue: $error',
        error: error,
        stackTrace: stackTrace,
      );
      _restoreBatchAfterFailure(batch, lastError: '$error');
    }
  }

  void _restoreBatchAfterFailure(
    List<QueuedEntityIntent> batch, {
    required String lastError,
  }) {
    final queued = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.queuedByEntityKey,
    );
    final inFlight = Map<EntitySyncKey, InFlightEntityIntent>.from(
      state.inFlightByEntityKey,
    );
    final retried = <PendingOp>[];

    for (final sent in batch) {
      inFlight.remove(sent.entityKey);
      if (queued.containsKey(sent.entityKey)) {
        continue;
      }
      final retriedPending = sent.pending.incrementAttempt();
      queued[sent.entityKey] = QueuedEntityIntent(
        entityKey: sent.entityKey,
        pending: retriedPending,
      );
      retried.add(retriedPending);
      _debugLog('queued.retry ${sent.entityKey} reason=flush_failure');
    }

    state = state.copyWith(
      queuedByEntityKey: queued,
      inFlightByEntityKey: inFlight,
      isFlushing: false,
      lastError: lastError,
    );
    _scheduleRetry(retried);
  }

  void _scheduleFlush({required bool flushImmediately}) {
    if (flushImmediately) {
      unawaited(flushNow());
      return;
    }

    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDelay, () {
      unawaited(flushNow());
    });
  }

  void _scheduleRetry(List<PendingOp> pending) {
    if (pending.isEmpty) {
      return;
    }

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

  bool _sameIntent(StrategyOp left, StrategyOp right) {
    return left.kind == right.kind &&
        left.entityType == right.entityType &&
        left.entityPublicId == right.entityPublicId &&
        left.pagePublicId == right.pagePublicId &&
        left.payload == right.payload &&
        left.sortIndex == right.sortIndex &&
        left.expectedRevision == right.expectedRevision &&
        left.expectedSequence == right.expectedSequence;
  }

  StrategyOp? _mergeQueuedIntent(StrategyOp existing, StrategyOp desired) {
    if (desired.kind == StrategyOpKind.delete &&
        existing.kind == StrategyOpKind.add) {
      return null;
    }

    if (existing.kind == StrategyOpKind.add && desired.kind == StrategyOpKind.patch) {
      return StrategyOp(
        opId: existing.opId,
        kind: StrategyOpKind.add,
        entityType: existing.entityType,
        entityPublicId: existing.entityPublicId,
        pagePublicId: existing.pagePublicId,
        payload: desired.payload ?? existing.payload,
        sortIndex: desired.sortIndex ?? existing.sortIndex,
        expectedRevision: existing.expectedRevision,
        expectedSequence: existing.expectedSequence,
      );
    }

    return StrategyOp(
      opId: existing.opId,
      kind: desired.kind,
      entityType: desired.entityType,
      entityPublicId: desired.entityPublicId ?? existing.entityPublicId,
      pagePublicId: desired.pagePublicId ?? existing.pagePublicId,
      payload: desired.payload ?? existing.payload,
      sortIndex: desired.sortIndex ?? existing.sortIndex,
      expectedRevision: desired.expectedRevision ?? existing.expectedRevision,
      expectedSequence: desired.expectedSequence ?? existing.expectedSequence,
    );
  }

  void _debugLog(String message) {
    assert(() {
      log(message, name: 'strategy_op_queue');
      return true;
    }());
  }
}
