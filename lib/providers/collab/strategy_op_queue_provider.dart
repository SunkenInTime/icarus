import 'dart:async';
import 'dart:developer';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:uuid/uuid.dart';

class StrategyOpQueueState {
  const StrategyOpQueueState({
    this.accountId,
    this.strategyPublicId,
    this.clientId,
    this.queuedByEntityKey = const <EntitySyncKey, QueuedEntityIntent>{},
    this.inFlightByEntityKey = const <EntitySyncKey, InFlightEntityIntent>{},
    this.successorByEntityKey = const <EntitySyncKey, QueuedEntityIntent>{},
    this.pausedByEntityKey = const <EntitySyncKey, QueuedEntityIntent>{},
    this.attentionByEntityKey = const <EntitySyncKey, QueuedEntityIntent>{},
    this.loadIssues = const <DurableOutboxLoadIssue>[],
    this.durableLoaded = false,
    this.hasDurabilityFailure = false,
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
  final Map<EntitySyncKey, QueuedEntityIntent> successorByEntityKey;
  final Map<EntitySyncKey, QueuedEntityIntent> pausedByEntityKey;
  final Map<EntitySyncKey, QueuedEntityIntent> attentionByEntityKey;
  final List<DurableOutboxLoadIssue> loadIssues;
  final bool durableLoaded;
  final bool hasDurabilityFailure;
  final bool isFlushing;
  final String? lastError;
  final DateTime? lastFlushAt;
  final List<OpAck> lastAcks;
  final List<AckedEntityIntent> lastAckBatch;

  bool get needsAttention =>
      loadIssues.isNotEmpty ||
      pausedByEntityKey.isNotEmpty ||
      attentionByEntityKey.isNotEmpty;

  bool get outboxIsReliable =>
      durableLoaded && loadIssues.isEmpty && !hasDurabilityFailure;

  List<PendingOp> get pending => <PendingOp>[
        ...queuedByEntityKey.values.map((intent) => intent.pending),
        ...inFlightByEntityKey.values.map((intent) => intent.pending),
        ...successorByEntityKey.values.map((intent) => intent.pending),
        ...pausedByEntityKey.values.map((intent) => intent.pending),
        ...attentionByEntityKey.values.map((intent) => intent.pending),
      ];

  StrategyOpQueueState copyWith({
    Map<EntitySyncKey, QueuedEntityIntent>? queuedByEntityKey,
    Map<EntitySyncKey, InFlightEntityIntent>? inFlightByEntityKey,
    Map<EntitySyncKey, QueuedEntityIntent>? successorByEntityKey,
    Map<EntitySyncKey, QueuedEntityIntent>? pausedByEntityKey,
    Map<EntitySyncKey, QueuedEntityIntent>? attentionByEntityKey,
    bool? hasDurabilityFailure,
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
      successorByEntityKey: successorByEntityKey ?? this.successorByEntityKey,
      pausedByEntityKey: pausedByEntityKey ?? this.pausedByEntityKey,
      attentionByEntityKey: attentionByEntityKey ?? this.attentionByEntityKey,
      loadIssues: loadIssues,
      durableLoaded: durableLoaded,
      hasDurabilityFailure:
          hasDurabilityFailure ?? this.hasDurabilityFailure,
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
  final Set<EntitySyncKey> _awaitingRemoteAdoption = {};
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
      hasDurabilityFailure: loaded.issues.isNotEmpty,
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
    _awaitingRemoteAdoption.clear();
    _offlineRetryCount = 0;
    final matching = accountId == null || strategyPublicId == null
        ? const <DurableOutboxRecord>[]
        : _recordsByStorageKey.values
            .where((record) =>
                record.accountId == accountId &&
                record.strategyPublicId == strategyPublicId)
            .toList(growable: false);
    final queued = <EntitySyncKey, QueuedEntityIntent>{};
    final successors = <EntitySyncKey, QueuedEntityIntent>{};
    final paused = <EntitySyncKey, QueuedEntityIntent>{};
    final attention = <EntitySyncKey, QueuedEntityIntent>{};
    for (final record in matching) {
      final intent = QueuedEntityIntent(
        entityKey: record.entityKey,
        pending: record.pending,
      );
      final successor = record.successorPending;
      if (successor != null) {
        successors[record.entityKey] = QueuedEntityIntent(
          entityKey: record.entityKey,
          pending: successor,
        );
      }
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
      successorByEntityKey: successors,
      pausedByEntityKey: paused,
      attentionByEntityKey: attention,
      loadIssues: state.loadIssues,
      durableLoaded: true,
      hasDurabilityFailure:
          state.hasDurabilityFailure || state.loadIssues.isNotEmpty,
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
              ...state.inFlightByEntityKey.keys
                  .where((key) => key.pageId == pageId),
              ...state.successorByEntityKey.keys
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
          hasDurabilityFailure: true,
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
    final successors = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.successorByEntityKey,
    );
    var changed = false;
    try {
      for (final key in keys) {
        if (_awaitingRemoteAdoption.contains(key)) continue;
        final desired = desiredOps[key];
        final existing = queued[key];
        final inFlightIntent = state.inFlightByEntityKey[key];
        final inFlight = inFlightIntent?.pending.op;
        final successorIntent = successors[key];
        final pausedIntent = paused[key];
        final attentionIntent = attention[key];

        // A rejected op remains the durable authority until the user
        // explicitly retries it. Reconciliation may update its successor, but
        // it must never make rejected work eligible for an automatic flush.
        if (attentionIntent != null) {
          if (desired == null) continue;
          final current = _recordForActiveKey(key);
          if (current == null) {
            throw StateError('Durable attention record is missing for $key.');
          }
          if (_sameIntent(attentionIntent.pending.op, desired)) {
            if (successorIntent != null) {
              await _putRecord(current.copyWith(
                clearSuccessorPending: true,
                updatedAt: DateTime.now(),
              ));
              successors.remove(key);
              changed = true;
            }
            continue;
          }
          if (successorIntent != null &&
              _sameIntent(successorIntent.pending.op, desired)) {
            continue;
          }
          final pending = PendingOp(
            op: successorIntent == null
                ? desired
                : _mergeQueuedIntent(successorIntent.pending.op, desired) ??
                    desired,
            clientId: successorIntent?.pending.clientId ??
                attentionIntent.pending.clientId,
          );
          await _putRecord(current.copyWith(
            status: DurableOutboxStatus.attention,
            successorPending: pending,
            updatedAt: DateTime.now(),
          ));
          successors[key] = QueuedEntityIntent(
            entityKey: key,
            pending: pending,
          );
          changed = true;
          continue;
        }

        if (desired == null) {
          if (inFlight != null || successorIntent != null) {
            continue;
          }
          final current = existing ?? pausedIntent;
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
          if (successorIntent != null) {
            await _putRecord(_recordFor(
              key: key,
              pending: inFlightIntent!.pending,
              status: DurableOutboxStatus.inFlight,
              clearSuccessorPending: true,
            ));
            successors.remove(key);
            changed = true;
          }
          continue;
        }

        if (inFlightIntent != null) {
          if (successorIntent != null &&
              _sameIntent(successorIntent.pending.op, desired)) {
            continue;
          }
          final pending = PendingOp(
            op: successorIntent == null
                ? desired
                : _mergeQueuedIntent(successorIntent.pending.op, desired) ??
                    desired,
            clientId: successorIntent?.pending.clientId ?? state.clientId!,
          );
          await _putRecord(_recordFor(
            key: key,
            pending: inFlightIntent.pending,
            status: DurableOutboxStatus.inFlight,
            successorPending: pending,
          ));
          successors[key] = QueuedEntityIntent(
            entityKey: key,
            pending: pending,
          );
          queued.remove(key);
          changed = true;
          continue;
        }

        if (existing != null && successorIntent != null) {
          if (_sameIntent(existing.pending.op, desired)) {
            await _putRecord(_recordFor(
              key: key,
              pending: existing.pending,
              status: DurableOutboxStatus.queued,
              clearSuccessorPending: true,
            ));
            successors.remove(key);
            changed = true;
            continue;
          }
          if (_sameIntent(successorIntent.pending.op, desired)) {
            continue;
          }
          final pending = PendingOp(
            op: _mergeQueuedIntent(successorIntent.pending.op, desired) ??
                desired,
            clientId: successorIntent.pending.clientId,
          );
          await _putRecord(_recordFor(
            key: key,
            pending: existing.pending,
            status: DurableOutboxStatus.queued,
            successorPending: pending,
          ));
          successors[key] = QueuedEntityIntent(
            entityKey: key,
            pending: pending,
          );
          changed = true;
          continue;
        }

        if (existing != null && _sameIntent(existing.pending.op, desired)) {
          continue;
        }

        final base = pausedIntent ?? existing;
        final merged = base == null
            ? desired
            : _mergeQueuedIntent(base.pending.op, desired);
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
          attempts: base?.pending.attempts ?? 0,
          lastAttemptAt: base?.pending.lastAttemptAt,
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
      successorByEntityKey: successors,
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
      final successors = Map<EntitySyncKey, QueuedEntityIntent>.from(
        state.successorByEntityKey,
      );
      var changed = false;
      try {
        for (final entry in state.attentionByEntityKey.entries) {
          final record = _recordForActiveKey(entry.key);
          final rejected = entry.value.pending;
          final rejectedOp = rejected.op;
          final successor = record?.successorPending;
          final retryOp = successor?.op ?? rejectedOp;
          final retryRevision =
              record?.latestServerRevision ?? rejectedOp.expectedRevision;
          if (retryRevision == null) continue;
          final isTombstoneRestore =
              (retryOp is ElementAddOp || retryOp is LineupAddOp) &&
                  (record?.lastError == 'missing_expected_revision' ||
                      record?.lastError == 'revision_mismatch');
          final rebasedOp = _rebaseRejectedOp(
            retryOp,
            retryRevision,
            preserveAdd: isTombstoneRestore,
          );
          final pending = PendingOp(
            op: rebasedOp,
            clientId: successor?.clientId ?? rejected.clientId,
          );
          await _putRecord(_recordFor(
            key: entry.key,
            pending: pending,
            status: DurableOutboxStatus.queued,
            clearSuccessorPending: true,
          ));
          queued[entry.key] = QueuedEntityIntent(
            entityKey: entry.key,
            pending: pending,
          );
          attention.remove(entry.key);
          successors.remove(entry.key);
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
        successorByEntityKey: successors,
        lastError: attentionMessage,
        clearError: attentionMessage == null,
      );
      _scheduleFlush(flushImmediately: flushImmediately);
    });
  }

  /// Discards selected server-rejected intents after an explicit user choice.
  ///
  /// Each durable record contains both the rejected predecessor and any newer
  /// successor for that entity. Removing the record discards both, without
  /// changing unrelated queued, in-flight, paused, or rejected work.
  Future<Set<EntitySyncKey>> discardRejected(
    Set<EntitySyncKey> entityKeys,
  ) {
    return _serializeWrite(() async {
      final attention = Map<EntitySyncKey, QueuedEntityIntent>.from(
        state.attentionByEntityKey,
      );
      final successors = Map<EntitySyncKey, QueuedEntityIntent>.from(
        state.successorByEntityKey,
      );
      final discarded = <EntitySyncKey>{};
      Object? persistenceError;
      StackTrace? persistenceStackTrace;

      for (final key in entityKeys) {
        final rejected = attention[key];
        final record = _recordForActiveKey(key);
        if (rejected == null ||
            record == null ||
            record.status != DurableOutboxStatus.attention ||
            record.pending.op.opId != rejected.pending.op.opId) {
          continue;
        }
        try {
          await _store.remove(record.storageKey);
          _recordsByStorageKey.remove(record.storageKey);
          attention.remove(key);
          successors.remove(key);
          _awaitingRemoteAdoption.add(key);
          discarded.add(key);
        } catch (error, stackTrace) {
          persistenceError = error;
          persistenceStackTrace = stackTrace;
          break;
        }
      }

      if (persistenceError != null) {
        log(
          'Durable outbox persistence failed: $persistenceError',
          name: 'strategy_outbox',
          error: persistenceError,
          stackTrace: persistenceStackTrace,
        );
      }
      final attentionMessage = _loadedAttentionMessage(
        loadIssues: state.loadIssues,
        paused: state.pausedByEntityKey,
        attention: attention,
      );
      final errorMessage = persistenceError == null
          ? attentionMessage
          : 'Cloud work could not be removed from the durable outbox: '
              '$persistenceError';
      state = state.copyWith(
        attentionByEntityKey: attention,
        successorByEntityKey: successors,
        lastError: errorMessage,
        clearError: errorMessage == null,
      );
      return Set<EntitySyncKey>.unmodifiable(discarded);
    });
  }

  void completeRemoteAdoption(Set<EntitySyncKey> entityKeys) {
    _awaitingRemoteAdoption.removeAll(entityKeys);
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
        !ref.read(convexConnectionSnapshotProvider)) {
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
    final queued = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.queuedByEntityKey,
    );
    final successors = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.successorByEntityKey,
    );
    final attention = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.attentionByEntityKey,
    );
    final acked = <AckedEntityIntent>[];
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
      final successor = current!.successorPending;
      // Only an accepted predecessor establishes a revision for automatic
      // promotion. A rejected predecessor leaves both intents in attention.
      final successorRevision = ack.appliedRevision;
      if (successor != null && ack.isAck && successorRevision != null) {
        final predecessorCreatedEntity = sent.pending.op is ElementAddOp ||
            sent.pending.op is LineupAddOp;
        final promoted = PendingOp(
          op: _rebaseRejectedOp(
            successor.op,
            successorRevision,
            preserveAdd: !predecessorCreatedEntity,
          ),
          clientId: successor.clientId,
        );
        await _putRecord(current.copyWith(
          pending: promoted,
          status: DurableOutboxStatus.queued,
          updatedAt: DateTime.now(),
          clearSuccessorPending: true,
          clearError: true,
          clearLatestServerRevision: true,
        ));
        queued[sent.entityKey] = QueuedEntityIntent(
          entityKey: sent.entityKey,
          pending: promoted,
        );
        successors.remove(sent.entityKey);
        attention.remove(sent.entityKey);
      } else if (successor != null) {
        final retained = current.copyWith(
          status: DurableOutboxStatus.attention,
          updatedAt: DateTime.now(),
          lastError: ack.reason ??
              'The final change is waiting for conflict resolution.',
          latestServerRevision: ack.latestRevision,
        );
        await _putRecord(retained);
        attention[sent.entityKey] = QueuedEntityIntent(
          entityKey: sent.entityKey,
          pending: sent.pending,
        );
      } else if (ack.isAck) {
        await _removeRecordIfCurrent(sent.entityKey, ack.opId);
        successors.remove(sent.entityKey);
      } else {
        final rejected = current.copyWith(
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
    final attentionMessage = _loadedAttentionMessage(
      loadIssues: state.loadIssues,
      paused: state.pausedByEntityKey,
      attention: attention,
    );
    state = state.copyWith(
      queuedByEntityKey: queued,
      inFlightByEntityKey: inFlight,
      successorByEntityKey: successors,
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
    PendingOp? successorPending,
    bool clearSuccessorPending = false,
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
      successorPending: clearSuccessorPending
          ? null
          : (successorPending ?? current?.successorPending),
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

  Future<T> _serializeWrite<T>(Future<T> Function() action) {
    final next = _writeTail.then((_) => action());
    _writeTail = next.then<void>((_) {}).catchError(
      (Object error, StackTrace stackTrace) {
        log('Outbox write failed: $error',
            name: 'strategy_outbox', error: error, stackTrace: stackTrace);
      },
    );
    return next;
  }

  void _recordPersistenceFailure(Object error, StackTrace stackTrace) {
    log('Durable outbox persistence failed: $error',
        name: 'strategy_outbox', error: error, stackTrace: stackTrace);
    state = state.copyWith(
      isFlushing: false,
      lastError: 'Cloud work could not be saved to the durable outbox: $error',
      hasDurabilityFailure: true,
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
    if ((existing is PageAddOp && desired is PageDeleteOp) ||
        (existing is ElementAddOp && desired is ElementDeleteOp) ||
        (existing is LineupAddOp && desired is LineupDeleteOp)) {
      return null;
    }
    final replacementOpId = const Uuid().v4();
    if (existing case PageAddOp()) {
      if (desired case PagePatchOp()) {
        return PageAddOp(
          opId: replacementOpId,
          pagePublicId: existing.pagePublicId,
          payload: {...existing.payload, ...desired.payload},
          sortIndex: existing.sortIndex,
          expectedStrategyRevision: existing.expectedStrategyRevision,
        );
      }
    }
    if (existing case ElementAddOp()) {
      if (desired case ElementPatchOp()) {
        return ElementAddOp(
          opId: replacementOpId,
          elementPublicId: existing.elementPublicId,
          pagePublicId: desired.pagePublicId ?? existing.pagePublicId,
          payload: desired.payload ?? existing.payload,
          sortIndex: desired.sortIndex ?? existing.sortIndex,
          expectedElementRevision: existing.expectedElementRevision,
        );
      }
    }
    if (existing case LineupAddOp()) {
      if (desired case LineupPatchOp()) {
        return LineupAddOp(
          opId: replacementOpId,
          lineupPublicId: existing.lineupPublicId,
          pagePublicId: desired.pagePublicId ?? existing.pagePublicId,
          payload: desired.payload ?? existing.payload,
          sortIndex: desired.sortIndex ?? existing.sortIndex,
          expectedLineupRevision: existing.expectedLineupRevision,
        );
      }
    }
    if (existing case StrategyPatchOp()) {
      if (desired case StrategyPatchOp()) {
        return StrategyPatchOp(
          opId: replacementOpId,
          payload: {...existing.payload, ...desired.payload},
          expectedStrategyRevision: desired.expectedStrategyRevision,
        );
      }
    }
    if (existing case PagePatchOp()) {
      if (desired case PagePatchOp()) {
        return PagePatchOp(
          opId: replacementOpId,
          pagePublicId: desired.pagePublicId,
          payload: {...existing.payload, ...desired.payload},
          expectedPageRevision: desired.expectedPageRevision,
        );
      }
    }
    if (existing case ElementPatchOp()) {
      if (desired case ElementPatchOp()) {
        return ElementPatchOp(
          opId: replacementOpId,
          elementPublicId: desired.elementPublicId,
          pagePublicId: desired.pagePublicId ?? existing.pagePublicId,
          payload: desired.payload ?? existing.payload,
          sortIndex: desired.sortIndex ?? existing.sortIndex,
          expectedElementRevision: desired.expectedElementRevision,
        );
      }
    }
    if (existing case LineupPatchOp()) {
      if (desired case LineupPatchOp()) {
        return LineupPatchOp(
          opId: replacementOpId,
          lineupPublicId: desired.lineupPublicId,
          pagePublicId: desired.pagePublicId ?? existing.pagePublicId,
          payload: desired.payload ?? existing.payload,
          sortIndex: desired.sortIndex ?? existing.sortIndex,
          expectedLineupRevision: desired.expectedLineupRevision,
        );
      }
    }
    return desired.withOpId(replacementOpId);
  }

  StrategyOp _rebaseRejectedOp(
    StrategyOp op,
    int revision, {
    required bool preserveAdd,
  }) {
    final opId = const Uuid().v4();
    return switch (op) {
      StrategyPatchOp(:final payload) => StrategyPatchOp(
          opId: opId,
          payload: payload,
          expectedStrategyRevision: revision,
        ),
      PageAddOp(:final pagePublicId, :final payload, :final sortIndex) =>
        PageAddOp(
          opId: opId,
          pagePublicId: pagePublicId,
          payload: payload,
          sortIndex: sortIndex,
          expectedStrategyRevision: revision,
        ),
      PagePatchOp(:final pagePublicId, :final payload) => PagePatchOp(
          opId: opId,
          pagePublicId: pagePublicId,
          payload: payload,
          expectedPageRevision: revision,
        ),
      PageDeleteOp(:final pagePublicId) => PageDeleteOp(
          opId: opId,
          pagePublicId: pagePublicId,
          expectedStrategyRevision: revision,
        ),
      PageReorderOp(:final pagePublicId, :final sortIndex) => PageReorderOp(
          opId: opId,
          pagePublicId: pagePublicId,
          sortIndex: sortIndex,
          expectedStrategyRevision: revision,
        ),
      PageContentPatchOp(:final pagePublicId, :final settings) =>
        PageContentPatchOp(
          opId: opId,
          pagePublicId: pagePublicId,
          settings: settings,
          expectedPageContentRevision: revision,
        ),
      ElementAddOp(
        :final elementPublicId,
        :final pagePublicId,
        :final payload,
        :final sortIndex,
      ) =>
        preserveAdd
            ? ElementAddOp(
                opId: opId,
                elementPublicId: elementPublicId,
                pagePublicId: pagePublicId,
                payload: payload,
                sortIndex: sortIndex,
                expectedElementRevision: revision,
              )
            : ElementPatchOp(
                opId: opId,
                elementPublicId: elementPublicId,
                pagePublicId: pagePublicId,
                payload: payload,
                sortIndex: sortIndex,
                expectedElementRevision: revision,
              ),
      ElementPatchOp(
        :final elementPublicId,
        :final pagePublicId,
        :final payload,
        :final sortIndex,
      ) =>
        ElementPatchOp(
          opId: opId,
          elementPublicId: elementPublicId,
          pagePublicId: pagePublicId,
          payload: payload,
          sortIndex: sortIndex,
          expectedElementRevision: revision,
        ),
      ElementDeleteOp(:final elementPublicId, :final pagePublicId) =>
        ElementDeleteOp(
          opId: opId,
          elementPublicId: elementPublicId,
          pagePublicId: pagePublicId,
          expectedElementRevision: revision,
        ),
      ElementReorderOp(
        :final elementPublicId,
        :final pagePublicId,
        :final sortIndex,
      ) =>
        ElementReorderOp(
          opId: opId,
          elementPublicId: elementPublicId,
          pagePublicId: pagePublicId,
          sortIndex: sortIndex,
          expectedElementRevision: revision,
        ),
      LineupAddOp(
        :final lineupPublicId,
        :final pagePublicId,
        :final payload,
        :final sortIndex,
      ) =>
        preserveAdd
            ? LineupAddOp(
                opId: opId,
                lineupPublicId: lineupPublicId,
                pagePublicId: pagePublicId,
                payload: payload,
                sortIndex: sortIndex,
                expectedLineupRevision: revision,
              )
            : LineupPatchOp(
                opId: opId,
                lineupPublicId: lineupPublicId,
                pagePublicId: pagePublicId,
                payload: payload,
                sortIndex: sortIndex,
                expectedLineupRevision: revision,
              ),
      LineupPatchOp(
        :final lineupPublicId,
        :final pagePublicId,
        :final payload,
        :final sortIndex,
      ) =>
        LineupPatchOp(
          opId: opId,
          lineupPublicId: lineupPublicId,
          pagePublicId: pagePublicId,
          payload: payload,
          sortIndex: sortIndex,
          expectedLineupRevision: revision,
        ),
      LineupDeleteOp(:final lineupPublicId, :final pagePublicId) =>
        LineupDeleteOp(
          opId: opId,
          lineupPublicId: lineupPublicId,
          pagePublicId: pagePublicId,
          expectedLineupRevision: revision,
        ),
      LineupReorderOp(
        :final lineupPublicId,
        :final pagePublicId,
        :final sortIndex,
      ) =>
        LineupReorderOp(
          opId: opId,
          lineupPublicId: lineupPublicId,
          pagePublicId: pagePublicId,
          sortIndex: sortIndex,
          expectedLineupRevision: revision,
        ),
    };
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
