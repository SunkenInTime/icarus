import 'dart:async';
import 'dart:developer';
import 'dart:math' as math;

import 'package:icarus/collab/convex_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:uuid/uuid.dart';

class StrategyOpQueueState {
  const StrategyOpQueueState({
    this.accountId,
    this.strategyPublicId,
    this.clientId,
    this.queuedByEntityKey = const <EntitySyncKey, QueuedEntityIntent>{},
    this.inFlightByEntityKey = const <EntitySyncKey, InFlightEntityIntent>{},
    this.pausedByEntityKey = const <EntitySyncKey, QueuedEntityIntent>{},
    this.attentionByEntityKey = const <EntitySyncKey, QueuedEntityIntent>{},
    this.loadIssues = const <DurableOutboxLoadIssue>[],
    this.durableLoaded = false,
    this.isFlushing = false,
    this.lastError,
    this.lastFlushAt,
    this.lastAcks = const <OpAck>[],
    this.lastAckBatch = const <AckedEntityIntent>[],
  });

  final String? accountId;
  final String? strategyPublicId;
  final String? clientId;
  final Map<EntitySyncKey, QueuedEntityIntent> queuedByEntityKey;
  final Map<EntitySyncKey, InFlightEntityIntent> inFlightByEntityKey;
  final Map<EntitySyncKey, QueuedEntityIntent> pausedByEntityKey;
  final Map<EntitySyncKey, QueuedEntityIntent> attentionByEntityKey;
  final List<DurableOutboxLoadIssue> loadIssues;
  final bool durableLoaded;
  final bool isFlushing;
  final String? lastError;
  final DateTime? lastFlushAt;
  final List<OpAck> lastAcks;
  final List<AckedEntityIntent> lastAckBatch;

  bool get needsAttention =>
      loadIssues.isNotEmpty ||
      pausedByEntityKey.isNotEmpty ||
      attentionByEntityKey.isNotEmpty;

  List<PendingOp> get pending => <PendingOp>[
        ...queuedByEntityKey.values.map((intent) => intent.pending),
        ...inFlightByEntityKey.values.map((intent) => intent.pending),
        ...pausedByEntityKey.values.map((intent) => intent.pending),
        ...attentionByEntityKey.values.map((intent) => intent.pending),
      ];

  StrategyOpQueueState copyWith({
    Map<EntitySyncKey, QueuedEntityIntent>? queuedByEntityKey,
    Map<EntitySyncKey, InFlightEntityIntent>? inFlightByEntityKey,
    Map<EntitySyncKey, QueuedEntityIntent>? pausedByEntityKey,
    Map<EntitySyncKey, QueuedEntityIntent>? attentionByEntityKey,
    bool? isFlushing,
    String? lastError,
    bool clearError = false,
    DateTime? lastFlushAt,
    List<OpAck>? lastAcks,
    List<AckedEntityIntent>? lastAckBatch,
  }) {
    return StrategyOpQueueState(
      accountId: accountId,
      strategyPublicId: strategyPublicId,
      clientId: clientId,
      queuedByEntityKey: queuedByEntityKey ?? this.queuedByEntityKey,
      inFlightByEntityKey: inFlightByEntityKey ?? this.inFlightByEntityKey,
      pausedByEntityKey: pausedByEntityKey ?? this.pausedByEntityKey,
      attentionByEntityKey: attentionByEntityKey ?? this.attentionByEntityKey,
      loadIssues: loadIssues,
      durableLoaded: durableLoaded,
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
  static const int _maxAttempts = 8;
  static const Duration _debounceDelay = Duration(milliseconds: 180);
  Timer? _debounceTimer;
  Timer? _retryTimer;
  int _offlineRetryCount = 0;
  late DurableStrategyOutboxStore _store;
  late Map<String, DurableOutboxRecord> _recordsByStorageKey;
  Future<void> _writeTail = Future<void>.value();

  ConvexStrategyRepository get _repo =>
      ref.read(convexStrategyRepositoryProvider);

  @override
  StrategyOpQueueState build() {
    _store = ref.read(durableStrategyOutboxStoreProvider);
    final loaded = _store.load();
    _recordsByStorageKey = {
      for (final record in loaded.records) record.storageKey: record,
    };
    ref.onDispose(() {
      _retryTimer?.cancel();
      _debounceTimer?.cancel();
    });
    return StrategyOpQueueState(
      clientId: const Uuid().v4(),
      loadIssues: loaded.issues,
      durableLoaded: true,
      lastError: loaded.issues.isEmpty
          ? null
          : 'The cloud outbox contains unreadable saved work.',
    );
  }

  void setActiveStrategy(
    String? strategyPublicId, {
    required String? accountId,
  }) {
    if (state.strategyPublicId == strategyPublicId &&
        state.accountId == accountId) return;

    _debounceTimer?.cancel();
    _retryTimer?.cancel();
    _offlineRetryCount = 0;
    final matching = accountId == null || strategyPublicId == null
        ? const <DurableOutboxRecord>[]
        : _recordsByStorageKey.values
            .where((record) =>
                record.accountId == accountId &&
                record.strategyPublicId == strategyPublicId)
            .toList(growable: false);
    final queued = <EntitySyncKey, QueuedEntityIntent>{};
    final paused = <EntitySyncKey, QueuedEntityIntent>{};
    final attention = <EntitySyncKey, QueuedEntityIntent>{};
    for (final record in matching) {
      final intent = QueuedEntityIntent(
        entityKey: record.entityKey,
        pending: record.pending,
      );
      switch (record.status) {
        case DurableOutboxStatus.queued:
        case DurableOutboxStatus.inFlight:
          // An interrupted request is replayed with its original op/client id.
          queued[record.entityKey] = intent;
        case DurableOutboxStatus.paused:
          paused[record.entityKey] = intent;
        case DurableOutboxStatus.attention:
          attention[record.entityKey] = intent;
      }
    }
    final clientId =
        matching.firstOrNull?.pending.clientId ?? const Uuid().v4();
    state = StrategyOpQueueState(
      accountId: accountId,
      strategyPublicId: strategyPublicId,
      clientId: clientId,
      queuedByEntityKey: queued,
      pausedByEntityKey: paused,
      attentionByEntityKey: attention,
      loadIssues: state.loadIssues,
      durableLoaded: true,
      lastError: _loadedAttentionMessage(
        loadIssues: state.loadIssues,
        paused: paused,
        attention: attention,
      ),
    );
    if (queued.isNotEmpty) _scheduleFlush(flushImmediately: true);
  }

  Future<void> enqueue(
    StrategyOp op, {
    bool flushImmediately = false,
  }) {
    final entityKey = EntitySyncKey.forStrategyOp(op);
    if (entityKey == null) return Future<void>.value();
    final pageId = entityKey.pageId;
    if (pageId != null) {
      return syncDesiredOpsForPage(
        pageId: pageId,
        desiredOpsByEntityKey: {entityKey: op},
        clearMissing: false,
        flushImmediately: flushImmediately,
      );
    }
    return syncDesiredGenericOp(
      entityKey: entityKey,
      desiredOp: op,
      flushImmediately: flushImmediately,
    );
  }

  Future<void> enqueueAll(
    Iterable<StrategyOp> ops, {
    bool flushImmediately = false,
  }) async {
    final byPage = <String, Map<EntitySyncKey, StrategyOp>>{};
    for (final op in ops) {
      final key = EntitySyncKey.forStrategyOp(op);
      if (key == null) continue;
      if (key.pageId == null) {
        await syncDesiredGenericOp(entityKey: key, desiredOp: op);
      } else {
        (byPage[key.pageId!] ??= <EntitySyncKey, StrategyOp>{})[key] = op;
      }
    }
    for (final entry in byPage.entries) {
      await syncDesiredOpsForPage(
        pageId: entry.key,
        desiredOpsByEntityKey: entry.value,
        clearMissing: false,
      );
    }
    _scheduleFlush(flushImmediately: flushImmediately);
  }

  Future<void> syncDesiredGenericOp({
    required EntitySyncKey entityKey,
    required StrategyOp? desiredOp,
    bool flushImmediately = false,
  }) {
    return _serializeWrite(() => _syncDesiredLocked(
          keys: <EntitySyncKey>{entityKey},
          desiredOps: <EntitySyncKey, StrategyOp?>{entityKey: desiredOp},
          flushImmediately: flushImmediately,
        ));
  }

  Future<void> syncDesiredOpsForPage({
    required String pageId,
    required Map<EntitySyncKey, StrategyOp> desiredOpsByEntityKey,
    bool clearMissing = true,
    bool flushImmediately = false,
  }) {
    return _serializeWrite(() async {
      final keys = clearMissing
          ? <EntitySyncKey>{
              ...state.queuedByEntityKey.keys
                  .where((key) => key.pageId == pageId),
              ...state.pausedByEntityKey.keys
                  .where((key) => key.pageId == pageId),
              ...desiredOpsByEntityKey.keys,
            }
          : desiredOpsByEntityKey.keys.toSet();
      await _syncDesiredLocked(
        keys: keys,
        desiredOps: <EntitySyncKey, StrategyOp?>{
          for (final key in keys) key: desiredOpsByEntityKey[key],
        },
        flushImmediately: flushImmediately,
      );
    });
  }

  Future<void> _syncDesiredLocked({
    required Set<EntitySyncKey> keys,
    required Map<EntitySyncKey, StrategyOp?> desiredOps,
    required bool flushImmediately,
  }) async {
    final accountId = state.accountId;
    final strategyPublicId = state.strategyPublicId;
    if (accountId == null || strategyPublicId == null) {
      if (desiredOps.values.any((op) => op != null)) {
        state = state.copyWith(
          lastError:
              'Cloud work could not be queued without an active account.',
        );
      }
      return;
    }

    final queued = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.queuedByEntityKey,
    );
    final paused = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.pausedByEntityKey,
    );
    final attention = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.attentionByEntityKey,
    );
    var changed = false;
    try {
      for (final key in keys) {
        final desired = desiredOps[key];
        final existing = queued[key];
        final inFlight = state.inFlightByEntityKey[key]?.pending.op;
        final pausedIntent = paused[key];
        final attentionIntent = attention[key];

        if (desired == null) {
          final current = existing ?? pausedIntent ?? attentionIntent;
          if (current != null) {
            await _removeRecordIfCurrent(key, current.pending.op.opId);
            queued.remove(key);
            paused.remove(key);
            attention.remove(key);
            changed = true;
          }
          continue;
        }

        if (inFlight != null && _sameIntent(desired, inFlight)) {
          if (existing != null) {
            await _removeRecordIfCurrent(key, existing.pending.op.opId);
            queued.remove(key);
            changed = true;
          }
          continue;
        }

        if (existing != null && _sameIntent(existing.pending.op, desired)) {
          continue;
        }

        // A rejected opId is an immutable server event. Reconciliation must
        // replace it with the newly based op instead of replaying the reject.
        final base = attentionIntent ?? pausedIntent ?? existing;
        final merged = attentionIntent != null
            ? desired
            : (base == null
                ? desired
                : _mergeQueuedIntent(base.pending.op, desired));
        if (merged == null) {
          if (base != null) {
            await _removeRecordIfCurrent(key, base.pending.op.opId);
            queued.remove(key);
            paused.remove(key);
            attention.remove(key);
            changed = true;
          }
          continue;
        }

        final pending = PendingOp(
          op: merged,
          clientId: base?.pending.clientId ?? state.clientId!,
          attempts: attentionIntent != null ? 0 : (base?.pending.attempts ?? 0),
          lastAttemptAt:
              attentionIntent != null ? null : base?.pending.lastAttemptAt,
        );
        final record = _recordFor(
          key: key,
          pending: pending,
          status: DurableOutboxStatus.queued,
        );
        await _putRecord(record);
        queued[key] = QueuedEntityIntent(entityKey: key, pending: pending);
        paused.remove(key);
        attention.remove(key);
        changed = true;
      }
    } catch (error, stackTrace) {
      _recordPersistenceFailure(error, stackTrace);
      return;
    }
    if (!changed) return;
    final attentionMessage = _loadedAttentionMessage(
      loadIssues: state.loadIssues,
      paused: paused,
      attention: attention,
    );
    state = state.copyWith(
      queuedByEntityKey: queued,
      pausedByEntityKey: paused,
      attentionByEntityKey: attention,
      lastError: attentionMessage,
      clearError: attentionMessage == null,
    );
    _scheduleFlush(flushImmediately: flushImmediately);
  }

  void clearStaleError() {
    if (state.lastError == null ||
        state.isFlushing ||
        state.pending.isNotEmpty ||
        state.loadIssues.isNotEmpty) return;
    state = state.copyWith(clearError: true);
  }

  Future<void> retryPaused({bool flushImmediately = true}) {
    return _serializeWrite(() async {
      if (state.pausedByEntityKey.isEmpty) return;
      final queued = Map<EntitySyncKey, QueuedEntityIntent>.from(
        state.queuedByEntityKey,
      );
      try {
        for (final entry in state.pausedByEntityKey.entries) {
          final pending = PendingOp(
            op: entry.value.pending.op,
            clientId: entry.value.pending.clientId,
          );
          await _putRecord(_recordFor(
            key: entry.key,
            pending: pending,
            status: DurableOutboxStatus.queued,
          ));
          queued[entry.key] =
              QueuedEntityIntent(entityKey: entry.key, pending: pending);
        }
      } catch (error, stackTrace) {
        _recordPersistenceFailure(error, stackTrace);
        return;
      }
      state = state.copyWith(
        queuedByEntityKey: queued,
        pausedByEntityKey: const <EntitySyncKey, QueuedEntityIntent>{},
        clearError:
            state.attentionByEntityKey.isEmpty && state.loadIssues.isEmpty,
      );
      _scheduleFlush(flushImmediately: flushImmediately);
    });
  }

  /// Rebases server-rejected intents only after an explicit user action.
  ///
  /// The server revision is stored with the durable attention record, so the
  /// same recovery remains available after an app restart. Ordinary page
  /// reconciliation never removes these records.
  Future<void> retryRejected({bool flushImmediately = true}) {
    return _serializeWrite(() async {
      if (state.attentionByEntityKey.isEmpty) return;
      final queued = Map<EntitySyncKey, QueuedEntityIntent>.from(
        state.queuedByEntityKey,
      );
      final attention = Map<EntitySyncKey, QueuedEntityIntent>.from(
        state.attentionByEntityKey,
      );
      var changed = false;
      try {
        for (final entry in state.attentionByEntityKey.entries) {
          final record = _recordForActiveKey(entry.key);
          final rejected = entry.value.pending;
          final rejectedOp = rejected.op;
          final retryRevision =
              record?.latestServerRevision ?? rejectedOp.expectedRevision;
          if (retryRevision == null) continue;
          final rebasedKind = rejectedOp.kind == StrategyOpKind.add &&
                  (rejectedOp.entityType == StrategyOpEntityType.element ||
                      rejectedOp.entityType == StrategyOpEntityType.lineup)
              ? StrategyOpKind.patch
              : rejectedOp.kind;
          final rebasedOp = StrategyOp(
            opId: const Uuid().v4(),
            kind: rebasedKind,
            entityType: rejectedOp.entityType,
            entityPublicId: rejectedOp.entityPublicId,
            pagePublicId: rejectedOp.pagePublicId,
            payload: rejectedOp.payload,
            sortIndex: rejectedOp.sortIndex,
            expectedRevision: retryRevision,
          );
          final pending = PendingOp(
            op: rebasedOp,
            clientId: rejected.clientId,
          );
          await _putRecord(_recordFor(
            key: entry.key,
            pending: pending,
            status: DurableOutboxStatus.queued,
          ));
          queued[entry.key] = QueuedEntityIntent(
            entityKey: entry.key,
            pending: pending,
          );
          attention.remove(entry.key);
          changed = true;
        }
      } catch (error, stackTrace) {
        _recordPersistenceFailure(error, stackTrace);
        return;
      }
      if (!changed) {
        state = state.copyWith(
          lastError: 'Some retained cloud work cannot be retried '
              'automatically because the server has no matching revision.',
        );
        return;
      }
      final attentionMessage = _loadedAttentionMessage(
        loadIssues: state.loadIssues,
        paused: state.pausedByEntityKey,
        attention: attention,
      );
      state = state.copyWith(
        queuedByEntityKey: queued,
        attentionByEntityKey: attention,
        lastError: attentionMessage,
        clearError: attentionMessage == null,
      );
      _scheduleFlush(flushImmediately: flushImmediately);
    });
  }

  Future<void> flushNow() async {
    await _writeTail;
    if (state.isFlushing) return;
    final strategyPublicId = state.strategyPublicId;
    if (strategyPublicId == null || state.queuedByEntityKey.isEmpty) return;

    final mode = ref.read(cloudCollabModeProvider);
    if (!mode.featureFlagEnabled || mode.forceLocalFallback) return;
    final auth = ref.read(authProvider);
    if (auth.hasActiveAuthIncident) {
      state = state.copyWith(
        lastError: 'Cloud auth incident active. Saved work is paused.',
      );
      return;
    }
    if (auth.user?.id != state.accountId) {
      state = state.copyWith(
        lastError: 'Cloud outbox belongs to a different account.',
      );
      return;
    }
    if (!auth.isAuthenticated ||
        !auth.isConvexUserReady ||
        !ConvexClient.instance.isConnected) {
      final message = !auth.isAuthenticated
          ? 'Not authenticated for cloud sync.'
          : (!auth.isConvexUserReady
              ? 'Cloud user setup is not ready.'
              : 'Cloud connection is offline.');
      _scheduleRetry(
        state.queuedByEntityKey.values.map((item) => item.pending).toList(),
        delay: _offlineRetryDelay(),
      );
      state = state.copyWith(lastError: message);
      return;
    }

    final candidates = state.queuedByEntityKey.values.toList(growable: false);
    if (candidates.isEmpty) return;
    final batchClientId = candidates.first.pending.clientId;
    final batch = candidates
        .where((intent) => intent.pending.clientId == batchClientId)
        .take(_maxBatchSize)
        .toList(growable: false);
    final queued = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.queuedByEntityKey,
    );
    final inFlight = Map<EntitySyncKey, InFlightEntityIntent>.from(
      state.inFlightByEntityKey,
    );
    final sentAt = DateTime.now();
    try {
      for (final intent in batch) {
        await _putRecord(_recordFor(
          key: intent.entityKey,
          pending: intent.pending,
          status: DurableOutboxStatus.inFlight,
        ));
        queued.remove(intent.entityKey);
        inFlight[intent.entityKey] = InFlightEntityIntent(
          entityKey: intent.entityKey,
          pending: intent.pending,
          sentAt: sentAt,
        );
      }
    } catch (error, stackTrace) {
      _recordPersistenceFailure(error, stackTrace);
      return;
    }
    state = state.copyWith(
      queuedByEntityKey: queued,
      inFlightByEntityKey: inFlight,
      isFlushing: true,
      clearError: true,
    );

    try {
      _retryTimer?.cancel();
      _retryTimer = null;
      _offlineRetryCount = 0;
      final acks = await _repo.applyBatch(
        strategyPublicId: strategyPublicId,
        clientId: batchClientId,
        ops: batch.map((intent) => intent.pending.op).toList(growable: false),
      );
      await _applyAcks(batch, acks);
      if (state.queuedByEntityKey.isNotEmpty) unawaited(flushNow());
    } catch (error, stackTrace) {
      if (isConvexUnauthenticatedError(error)) {
        unawaited(ref.read(authProvider.notifier).reportConvexUnauthenticated(
              source: 'strategy_op_queue:flush',
              error: error,
              stackTrace: stackTrace,
            ));
      } else {
        log('Failed flushing op queue: $error',
            error: error, stackTrace: stackTrace);
      }
      await _restoreBatchAfterFailure(batch, lastError: '$error');
    }
  }

  Future<void> _applyAcks(
    List<QueuedEntityIntent> batch,
    List<OpAck> acks,
  ) async {
    final byOpId = {for (final item in batch) item.pending.op.opId: item};
    final ackByOpId = {for (final ack in acks) ack.opId: ack};
    if (ackByOpId.length != batch.length) {
      throw StateError(
        'Server returned an incomplete operation result batch.',
      );
    }
    final inFlight = Map<EntitySyncKey, InFlightEntityIntent>.from(
      state.inFlightByEntityKey,
    );
    final attention = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.attentionByEntityKey,
    );
    final acked = <AckedEntityIntent>[];
    try {
      for (final ack in acks) {
        final sent = byOpId[ack.opId];
        if (sent == null) continue;
        inFlight.remove(sent.entityKey);
        acked.add(AckedEntityIntent(
          entityKey: sent.entityKey,
          op: sent.pending.op,
          ack: ack,
        ));
        final current = _recordForActiveKey(sent.entityKey);
        if (current?.pending.op.opId != ack.opId) continue;
        if (ack.isAck) {
          await _removeRecordIfCurrent(sent.entityKey, ack.opId);
        } else {
          final rejected = current!.copyWith(
            status: DurableOutboxStatus.attention,
            updatedAt: DateTime.now(),
            lastError: ack.reason ?? 'The server rejected this change.',
            latestServerRevision: ack.latestRevision,
          );
          await _putRecord(rejected);
          attention[sent.entityKey] = QueuedEntityIntent(
            entityKey: sent.entityKey,
            pending: sent.pending,
          );
        }
      }
    } catch (error, stackTrace) {
      _recordPersistenceFailure(error, stackTrace);
      return;
    }
    final attentionMessage = _loadedAttentionMessage(
      loadIssues: state.loadIssues,
      paused: state.pausedByEntityKey,
      attention: attention,
    );
    state = state.copyWith(
      inFlightByEntityKey: inFlight,
      attentionByEntityKey: attention,
      isFlushing: false,
      lastFlushAt: DateTime.now(),
      lastAcks: acks,
      lastAckBatch: acked,
      lastError: attentionMessage,
      clearError: attentionMessage == null,
    );
  }

  Future<void> _restoreBatchAfterFailure(
    List<QueuedEntityIntent> batch, {
    required String lastError,
  }) async {
    final queued = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.queuedByEntityKey,
    );
    final inFlight = Map<EntitySyncKey, InFlightEntityIntent>.from(
      state.inFlightByEntityKey,
    );
    final paused = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.pausedByEntityKey,
    );
    final retrying = <PendingOp>[];
    try {
      for (final sent in batch) {
        inFlight.remove(sent.entityKey);
        if (queued.containsKey(sent.entityKey)) continue;
        final pending = sent.pending.incrementAttempt();
        final isPaused = pending.attempts >= _maxAttempts;
        await _putRecord(_recordFor(
          key: sent.entityKey,
          pending: pending,
          status: isPaused
              ? DurableOutboxStatus.paused
              : DurableOutboxStatus.queued,
          lastError: lastError,
        ));
        final intent = QueuedEntityIntent(
          entityKey: sent.entityKey,
          pending: pending,
        );
        if (isPaused) {
          paused[sent.entityKey] = intent;
        } else {
          queued[sent.entityKey] = intent;
          retrying.add(pending);
        }
      }
    } catch (error, stackTrace) {
      _recordPersistenceFailure(error, stackTrace);
      return;
    }
    state = state.copyWith(
      queuedByEntityKey: queued,
      inFlightByEntityKey: inFlight,
      pausedByEntityKey: paused,
      isFlushing: false,
      lastError: paused.isEmpty
          ? lastError
          : '$lastError (retry paused after $_maxAttempts attempts)',
    );
    _scheduleRetry(retrying);
  }

  DurableOutboxRecord _recordFor({
    required EntitySyncKey key,
    required PendingOp pending,
    required DurableOutboxStatus status,
    String? lastError,
  }) {
    final current = _recordForActiveKey(key);
    final now = DateTime.now();
    return DurableOutboxRecord(
      accountId: state.accountId!,
      strategyPublicId: state.strategyPublicId!,
      entityKey: key,
      pending: pending,
      status: status,
      createdAt: current?.createdAt ?? now,
      updatedAt: now,
      lastError: lastError,
    );
  }

  DurableOutboxRecord? _recordForActiveKey(EntitySyncKey key) {
    final accountId = state.accountId;
    final strategyPublicId = state.strategyPublicId;
    if (accountId == null || strategyPublicId == null) return null;
    return _recordsByStorageKey[DurableOutboxRecord.createStorageKey(
      accountId: accountId,
      strategyPublicId: strategyPublicId,
      entityKey: key,
    )];
  }

  Future<void> _putRecord(DurableOutboxRecord record) async {
    await _store.put(record);
    _recordsByStorageKey[record.storageKey] = record;
  }

  Future<void> _removeRecordIfCurrent(
    EntitySyncKey key,
    String opId,
  ) async {
    final record = _recordForActiveKey(key);
    if (record == null || record.pending.op.opId != opId) return;
    await _store.remove(record.storageKey);
    _recordsByStorageKey.remove(record.storageKey);
  }

  Future<void> _serializeWrite(Future<void> Function() action) {
    final next = _writeTail.then((_) => action());
    _writeTail = next.catchError((Object error, StackTrace stackTrace) {
      log('Outbox write failed: $error',
          name: 'strategy_outbox', error: error, stackTrace: stackTrace);
    });
    return next;
  }

  void _recordPersistenceFailure(Object error, StackTrace stackTrace) {
    log('Durable outbox persistence failed: $error',
        name: 'strategy_outbox', error: error, stackTrace: stackTrace);
    state = state.copyWith(
      isFlushing: false,
      lastError: 'Cloud work could not be saved to the durable outbox: $error',
    );
  }

  void _scheduleFlush({required bool flushImmediately}) {
    if (flushImmediately) {
      unawaited(flushNow());
      return;
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDelay, () => unawaited(flushNow()));
  }

  void _scheduleRetry(List<PendingOp> pending, {Duration? delay}) {
    if (pending.isEmpty) return;
    final maxAttempt = pending.fold<int>(
      0,
      (value, item) => math.max(value, item.attempts),
    );
    final retryDelay =
        delay ?? Duration(milliseconds: 300 * (1 << maxAttempt.clamp(0, 6)));
    _retryTimer?.cancel();
    _retryTimer = Timer(retryDelay, () => unawaited(flushNow()));
  }

  Duration _offlineRetryDelay() {
    final exponent = _offlineRetryCount.clamp(0, 6);
    _offlineRetryCount += 1;
    return Duration(milliseconds: 300 * (1 << exponent));
  }

  bool _sameIntent(StrategyOp left, StrategyOp right) {
    return left.kind == right.kind &&
        left.entityType == right.entityType &&
        left.entityPublicId == right.entityPublicId &&
        left.pagePublicId == right.pagePublicId &&
        cloudJsonEquivalent(left.payload, right.payload) &&
        left.sortIndex == right.sortIndex &&
        left.expectedRevision == right.expectedRevision;
  }

  StrategyOp? _mergeQueuedIntent(StrategyOp existing, StrategyOp desired) {
    if (desired.kind == StrategyOpKind.delete &&
        existing.kind == StrategyOpKind.add) return null;
    if (existing.kind == StrategyOpKind.add &&
        desired.kind == StrategyOpKind.patch) {
      return StrategyOp(
        opId: existing.opId,
        kind: StrategyOpKind.add,
        entityType: existing.entityType,
        entityPublicId: existing.entityPublicId,
        pagePublicId: existing.pagePublicId,
        payload: desired.payload ?? existing.payload,
        sortIndex: desired.sortIndex ?? existing.sortIndex,
        expectedRevision: existing.expectedRevision,
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
    );
  }

  String? _loadedAttentionMessage({
    required List<DurableOutboxLoadIssue> loadIssues,
    required Map<EntitySyncKey, QueuedEntityIntent> paused,
    required Map<EntitySyncKey, QueuedEntityIntent> attention,
  }) {
    if (loadIssues.isNotEmpty) {
      return 'The cloud outbox contains unreadable saved work.';
    }
    if (attention.isNotEmpty) return 'Some saved work needs attention.';
    if (paused.isNotEmpty) return 'Some saved work is paused after retries.';
    return null;
  }
}
