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

class StrategyOutboxSession {
  const StrategyOutboxSession({
    required this.accountId,
    required this.isReady,
    required this.hasAuthIncident,
  });

  final String? accountId;
  final bool isReady;
  final bool hasAuthIncident;
}

final strategyOutboxSessionProvider = Provider<StrategyOutboxSession>((ref) {
  final auth = ref.watch(authProvider);
  return StrategyOutboxSession(
    accountId: auth.user?.id,
    isReady: auth.isAuthenticated && auth.isConvexUserReady,
    hasAuthIncident: auth.hasActiveAuthIncident,
  );
});

class StrategyOutboxSummary {
  const StrategyOutboxSummary({
    required this.strategyPublicId,
    required this.queuedCount,
    required this.inFlightCount,
    required this.pausedCount,
    required this.attentionCount,
    required this.successorCount,
    this.reason,
  });

  final String strategyPublicId;
  final int queuedCount;
  final int inFlightCount;
  final int pausedCount;
  final int attentionCount;
  final int successorCount;
  final String? reason;

  int get workCount =>
      queuedCount +
      inFlightCount +
      pausedCount +
      attentionCount +
      successorCount;
  bool get hasRunnableWork => queuedCount > 0 || inFlightCount > 0;
  bool get needsAttention => pausedCount > 0 || attentionCount > 0;
}

class AccountStrategyOutboxSummary {
  const AccountStrategyOutboxSummary({
    this.accountId,
    this.strategies = const <String, StrategyOutboxSummary>{},
  });

  final String? accountId;
  final Map<String, StrategyOutboxSummary> strategies;

  int get workCount => strategies.values.fold<int>(
        0,
        (total, strategy) => total + strategy.workCount,
      );
  int get strategyCount => strategies.length;
  bool get hasWork => workCount > 0;
  bool get hasRunnableWork =>
      strategies.values.any((strategy) => strategy.hasRunnableWork);
  bool get needsAttention =>
      strategies.values.any((strategy) => strategy.needsAttention);
}

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
    this.accountOutbox = const AccountStrategyOutboxSummary(),
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
  final AccountStrategyOutboxSummary accountOutbox;

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
    AccountStrategyOutboxSummary? accountOutbox,
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
      accountOutbox: accountOutbox ?? this.accountOutbox,
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
  Timer? _backgroundRetryTimer;
  int _offlineRetryCount = 0;
  bool _networkBusy = false;
  ({String accountId, String strategyPublicId})? _drainingStrategy;
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
      _backgroundRetryTimer?.cancel();
    });
    ref.listen<StrategyOutboxSession>(strategyOutboxSessionProvider,
        (previous, next) {
      if (previous?.accountId != next.accountId) {
        setCurrentAccount(next.accountId);
      }
      final becameReady = !(previous?.isReady ?? false) && next.isReady;
      final recovered = (previous?.hasAuthIncident ?? false) &&
          !next.hasAuthIncident;
      if (becameReady || recovered) {
        retryCurrentAccount();
      }
    });
    ref.listen<AsyncValue<bool>>(convexConnectionProvider, (previous, next) {
      if (previous?.valueOrNull != true && next.valueOrNull == true) {
        _scheduleBackgroundDrain(ignoreBackoff: true);
      }
    });
    final session = ref.read(strategyOutboxSessionProvider);
    if (session.accountId != null &&
        loaded.records
            .any((record) => record.accountId == session.accountId)) {
      _backgroundRetryTimer = Timer(
        Duration.zero,
        () => retryCurrentAccount(),
      );
    }
    return StrategyOpQueueState(
      accountId: session.accountId,
      clientId: const Uuid().v4(),
      loadIssues: loaded.issues,
      durableLoaded: true,
      hasDurabilityFailure: loaded.issues.isNotEmpty,
      lastError: loaded.issues.isEmpty
          ? null
          : 'The cloud outbox contains unreadable saved work.',
      accountOutbox: _accountSummary(session.accountId),
    );
  }

  void setCurrentAccount(String? accountId) {
    if (state.accountId == accountId) {
      _publishAccountSummary();
      _scheduleBackgroundDrain(ignoreBackoff: true);
      return;
    }
    setActiveStrategy(null, accountId: accountId);
  }

  void setActiveStrategy(
    String? strategyPublicId, {
    required String? accountId,
  }) {
    if (state.strategyPublicId == strategyPublicId &&
        state.accountId == accountId) {
      _publishAccountSummary();
      _scheduleBackgroundDrain(ignoreBackoff: true);
      return;
    }

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
    final inFlight = <EntitySyncKey, InFlightEntityIntent>{};
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
          queued[record.entityKey] = intent;
        case DurableOutboxStatus.inFlight:
          if (_drainingStrategy ==
              (accountId: accountId, strategyPublicId: strategyPublicId)) {
            inFlight[record.entityKey] = InFlightEntityIntent(
              entityKey: record.entityKey,
              pending: record.pending,
              sentAt: record.updatedAt,
            );
          } else {
            // An interrupted request is replayed with its original op/client
            // id after restart.
            queued[record.entityKey] = intent;
          }
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
      inFlightByEntityKey: inFlight,
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
      accountOutbox: _accountSummary(accountId),
    );
    if (queued.isNotEmpty && inFlight.isEmpty) {
      _scheduleFlush(flushImmediately: true);
    }
    _scheduleBackgroundDrain(ignoreBackoff: true);
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
    if (_networkBusy) return;
    final accountId = state.accountId;
    final strategyPublicId = state.strategyPublicId;
    if (accountId == null ||
        strategyPublicId == null ||
        state.queuedByEntityKey.isEmpty) {
      return;
    }

    await _flushStrategy(
      accountId: accountId,
      strategyPublicId: strategyPublicId,
      isBackground: false,
    );
  }

  Future<void> _flushStrategy({
    required String accountId,
    required String strategyPublicId,
    required bool isBackground,
    bool ignoreBackoff = false,
  }) async {
    if (_networkBusy) return;

    final mode = ref.read(cloudCollabModeProvider);
    if (!mode.featureFlagEnabled || mode.forceLocalFallback) return;
    final auth = ref.read(authProvider);
    if (auth.hasActiveAuthIncident) {
      if (!isBackground && _isActive(accountId, strategyPublicId)) {
        state = state.copyWith(
          lastError: 'Cloud auth incident active. Saved work is paused.',
        );
      }
      return;
    }
    if (auth.user?.id != accountId) {
      if (!isBackground && _isActive(accountId, strategyPublicId)) {
        state = state.copyWith(
          lastError: 'Cloud outbox belongs to a different account.',
        );
      }
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
      if (!isBackground && _isActive(accountId, strategyPublicId)) {
        _scheduleRetry(
          state.queuedByEntityKey.values.map((item) => item.pending).toList(),
          delay: _offlineRetryDelay(),
        );
        state = state.copyWith(lastError: message);
      }
      return;
    }

    _networkBusy = true;
    _drainingStrategy = (
      accountId: accountId,
      strategyPublicId: strategyPublicId,
    );
    List<DurableOutboxRecord> batch;
    var batchSucceeded = false;
    try {
      batch = await _claimBatch(
        accountId: accountId,
        strategyPublicId: strategyPublicId,
        ignoreBackoff: ignoreBackoff || !isBackground,
      );
    } catch (error, stackTrace) {
      _recordPersistenceFailure(error, stackTrace);
      _finishNetworkLane();
      return;
    }
    if (batch.isEmpty) {
      _finishNetworkLane();
      _scheduleBackgroundDrain();
      return;
    }
    final batchClientId = batch.first.pending.clientId;
    _refreshActiveQueueView(
      isFlushing: _isActive(accountId, strategyPublicId),
      clearError: true,
    );

    try {
      _retryTimer?.cancel();
      _retryTimer = null;
      _offlineRetryCount = 0;
      final acks = await _repo.applyBatch(
        strategyPublicId: strategyPublicId,
        clientId: batchClientId,
        ops: batch.map((record) => record.pending.op).toList(growable: false),
      );
      await _applyAcksForRecords(batch, acks);
      batchSucceeded = true;
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
      await _restoreRecordsAfterFailure(batch, lastError: '$error');
    } finally {
      _finishNetworkLane();
    }

    if (state.queuedByEntityKey.isNotEmpty &&
        (isBackground || batchSucceeded)) {
      unawaited(flushNow());
    } else {
      _scheduleBackgroundDrain();
    }
  }

  Future<List<DurableOutboxRecord>> _claimBatch({
    required String accountId,
    required String strategyPublicId,
    required bool ignoreBackoff,
  }) {
    return _serializeWrite(() async {
      final now = DateTime.now();
      final candidates = _recordsByStorageKey.values
          .where((record) =>
              record.accountId == accountId &&
              record.strategyPublicId == strategyPublicId &&
              (record.status == DurableOutboxStatus.queued ||
                  record.status == DurableOutboxStatus.inFlight) &&
              (ignoreBackoff || !_nextAttemptAt(record).isAfter(now)))
          .toList(growable: false);
      if (candidates.isEmpty) return const <DurableOutboxRecord>[];
      final batchClientId = candidates.first.pending.clientId;
      final selected = candidates
          .where((record) => record.pending.clientId == batchClientId)
          .take(_maxBatchSize)
          .toList(growable: false);
      final claimed = <DurableOutboxRecord>[];
      for (final record in selected) {
        final current = _recordsByStorageKey[record.storageKey];
        if (current == null ||
            current.pending.op.opId != record.pending.op.opId ||
            (current.status != DurableOutboxStatus.queued &&
                current.status != DurableOutboxStatus.inFlight)) {
          continue;
        }
        final inFlight = current.copyWith(
          status: DurableOutboxStatus.inFlight,
          updatedAt: now,
          clearError: true,
        );
        await _putRecord(inFlight);
        claimed.add(inFlight);
      }
      return claimed;
    });
  }

  Future<void> _applyAcksForRecords(
    List<DurableOutboxRecord> batch,
    List<OpAck> acks,
  ) {
    return _serializeWrite(() => _applyAcksForRecordsLocked(batch, acks));
  }

  Future<void> _applyAcksForRecordsLocked(
    List<DurableOutboxRecord> batch,
    List<OpAck> acks,
  ) async {
    final byOpId = {for (final item in batch) item.pending.op.opId: item};
    final ackByOpId = {for (final ack in acks) ack.opId: ack};
    if (ackByOpId.length != batch.length ||
        !ackByOpId.keys.toSet().containsAll(byOpId.keys)) {
      throw StateError(
        'Server returned an incomplete operation result batch.',
      );
    }
    final acked = <AckedEntityIntent>[];
    for (final ack in acks) {
      final sent = byOpId[ack.opId];
      if (sent == null) continue;
      acked.add(AckedEntityIntent(
        entityKey: sent.entityKey,
        op: sent.pending.op,
        ack: ack,
      ));
      final current = _recordsByStorageKey[sent.storageKey];
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
      } else if (successor != null) {
        final retained = current.copyWith(
          status: DurableOutboxStatus.attention,
          updatedAt: DateTime.now(),
          lastError: ack.reason ??
              'The final change is waiting for conflict resolution.',
          latestServerRevision: ack.latestRevision,
        );
        await _putRecord(retained);
      } else if (ack.isAck) {
        await _removeRecordByStorageKeyIfCurrent(sent.storageKey, ack.opId);
      } else {
        final rejected = current.copyWith(
          status: DurableOutboxStatus.attention,
          updatedAt: DateTime.now(),
          lastError: ack.reason ?? 'The server rejected this change.',
          latestServerRevision: ack.latestRevision,
        );
        await _putRecord(rejected);
      }
    }
    final first = batch.first;
    if (_isActive(first.accountId, first.strategyPublicId)) {
      _refreshActiveQueueView(
        isFlushing: false,
        lastAcks: acks,
        lastAckBatch: acked,
        lastFlushAt: DateTime.now(),
      );
    } else {
      _refreshActiveQueueView();
    }
  }

  Future<void> _restoreRecordsAfterFailure(
    List<DurableOutboxRecord> batch, {
    required String lastError,
  }) {
    return _serializeWrite(
      () => _restoreRecordsAfterFailureLocked(batch, lastError: lastError),
    );
  }

  Future<void> _restoreRecordsAfterFailureLocked(
    List<DurableOutboxRecord> batch, {
    required String lastError,
  }) async {
    final retrying = <PendingOp>[];
    try {
      for (final sent in batch) {
        final current = _recordsByStorageKey[sent.storageKey];
        if (current == null ||
            current.pending.op.opId != sent.pending.op.opId) {
          continue;
        }
        final pending = current.pending.incrementAttempt();
        final isPaused = pending.attempts >= _maxAttempts;
        await _putRecord(current.copyWith(
          pending: pending,
          status: isPaused
              ? DurableOutboxStatus.paused
              : DurableOutboxStatus.queued,
          updatedAt: DateTime.now(),
          lastError: lastError,
        ));
        if (!isPaused) retrying.add(pending);
      }
    } catch (error, stackTrace) {
      _recordPersistenceFailure(error, stackTrace);
      return;
    }
    final draining = _drainingStrategy;
    if (draining != null &&
        _isActive(draining.accountId, draining.strategyPublicId)) {
      _refreshActiveQueueView(
        isFlushing: false,
        lastError: lastError,
        useProvidedError: true,
      );
      _scheduleRetry(retrying);
    } else {
      _refreshActiveQueueView();
    }
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
    _publishAccountSummary();
  }

  Future<void> _removeRecordIfCurrent(
    EntitySyncKey key,
    String opId,
  ) async {
    final record = _recordForActiveKey(key);
    if (record == null || record.pending.op.opId != opId) return;
    await _store.remove(record.storageKey);
    _recordsByStorageKey.remove(record.storageKey);
    _publishAccountSummary();
  }

  Future<void> _removeRecordByStorageKeyIfCurrent(
    String storageKey,
    String opId,
  ) async {
    final record = _recordsByStorageKey[storageKey];
    if (record == null || record.pending.op.opId != opId) return;
    await _store.remove(storageKey);
    _recordsByStorageKey.remove(storageKey);
    _publishAccountSummary();
  }

  bool _isActive(String accountId, String strategyPublicId) {
    return state.accountId == accountId &&
        state.strategyPublicId == strategyPublicId;
  }

  void _refreshActiveQueueView({
    bool? isFlushing,
    String? lastError,
    bool useProvidedError = false,
    DateTime? lastFlushAt,
    List<OpAck>? lastAcks,
    List<AckedEntityIntent>? lastAckBatch,
    bool clearError = false,
  }) {
    final accountId = state.accountId;
    final strategyPublicId = state.strategyPublicId;
    final queued = <EntitySyncKey, QueuedEntityIntent>{};
    final inFlight = <EntitySyncKey, InFlightEntityIntent>{};
    final successors = <EntitySyncKey, QueuedEntityIntent>{};
    final paused = <EntitySyncKey, QueuedEntityIntent>{};
    final attention = <EntitySyncKey, QueuedEntityIntent>{};
    if (accountId != null && strategyPublicId != null) {
      final isActivelyDraining = _drainingStrategy ==
          (accountId: accountId, strategyPublicId: strategyPublicId);
      for (final record in _recordsByStorageKey.values) {
        if (record.accountId != accountId ||
            record.strategyPublicId != strategyPublicId) {
          continue;
        }
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
            queued[record.entityKey] = intent;
          case DurableOutboxStatus.inFlight:
            if (isActivelyDraining) {
              inFlight[record.entityKey] = InFlightEntityIntent(
                entityKey: record.entityKey,
                pending: record.pending,
                sentAt: record.updatedAt,
              );
            } else {
              queued[record.entityKey] = intent;
            }
          case DurableOutboxStatus.paused:
            paused[record.entityKey] = intent;
          case DurableOutboxStatus.attention:
            attention[record.entityKey] = intent;
        }
      }
    }
    final attentionMessage = _loadedAttentionMessage(
      loadIssues: state.loadIssues,
      paused: paused,
      attention: attention,
    );
    final effectiveError = attentionMessage ??
        (useProvidedError ? lastError : (clearError ? null : state.lastError));
    state = state.copyWith(
      queuedByEntityKey: queued,
      inFlightByEntityKey: inFlight,
      successorByEntityKey: successors,
      pausedByEntityKey: paused,
      attentionByEntityKey: attention,
      accountOutbox: _accountSummary(accountId),
      isFlushing: isFlushing,
      lastError: effectiveError,
      clearError: effectiveError == null,
      lastFlushAt: lastFlushAt,
      lastAcks: lastAcks,
      lastAckBatch: lastAckBatch,
    );
  }

  void _finishNetworkLane() {
    _networkBusy = false;
    _drainingStrategy = null;
    if (state.isFlushing) {
      _refreshActiveQueueView(isFlushing: false);
    }
  }

  AccountStrategyOutboxSummary _accountSummary(String? accountId) {
    if (accountId == null) return const AccountStrategyOutboxSummary();
    final recordsByStrategy = <String, List<DurableOutboxRecord>>{};
    for (final record in _recordsByStorageKey.values) {
      if (record.accountId != accountId) continue;
      (recordsByStrategy[record.strategyPublicId] ??= <DurableOutboxRecord>[])
          .add(record);
    }
    return AccountStrategyOutboxSummary(
      accountId: accountId,
      strategies: <String, StrategyOutboxSummary>{
        for (final entry in recordsByStrategy.entries)
          entry.key: StrategyOutboxSummary(
            strategyPublicId: entry.key,
            queuedCount: entry.value
                .where((record) => record.status == DurableOutboxStatus.queued)
                .length,
            inFlightCount: entry.value
                .where(
                    (record) => record.status == DurableOutboxStatus.inFlight)
                .length,
            pausedCount: entry.value
                .where((record) => record.status == DurableOutboxStatus.paused)
                .length,
            attentionCount: entry.value
                .where(
                    (record) => record.status == DurableOutboxStatus.attention)
                .length,
            successorCount: entry.value
                .where((record) => record.successorPending != null)
                .length,
            reason: entry.value
                .where((record) => record.lastError?.isNotEmpty ?? false)
                .map((record) => record.lastError)
                .firstOrNull,
          ),
      },
    );
  }

  void _publishAccountSummary() {
    final summary = _accountSummary(state.accountId);
    if (_sameAccountSummary(state.accountOutbox, summary)) return;
    state = state.copyWith(accountOutbox: summary);
  }

  bool _sameAccountSummary(
    AccountStrategyOutboxSummary left,
    AccountStrategyOutboxSummary right,
  ) {
    if (left.accountId != right.accountId ||
        left.strategies.length != right.strategies.length) {
      return false;
    }
    for (final entry in left.strategies.entries) {
      final other = right.strategies[entry.key];
      if (other == null ||
          other.queuedCount != entry.value.queuedCount ||
          other.inFlightCount != entry.value.inFlightCount ||
          other.pausedCount != entry.value.pausedCount ||
          other.attentionCount != entry.value.attentionCount ||
          other.successorCount != entry.value.successorCount ||
          other.reason != entry.value.reason) {
        return false;
      }
    }
    return true;
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

  void retryCurrentAccount() {
    _scheduleBackgroundDrain(ignoreBackoff: true);
    if (state.queuedByEntityKey.isNotEmpty) {
      unawaited(flushNow());
    }
  }

  void _scheduleBackgroundDrain({bool ignoreBackoff = false}) {
    _backgroundRetryTimer?.cancel();
    final accountId = state.accountId;
    if (accountId == null) return;
    final activeStrategyId = state.strategyPublicId;
    final now = DateTime.now();
    final candidates = _recordsByStorageKey.values
        .where((record) =>
            record.accountId == accountId &&
            record.strategyPublicId != activeStrategyId &&
            (record.status == DurableOutboxStatus.queued ||
                record.status == DurableOutboxStatus.inFlight))
        .toList(growable: false);
    if (candidates.isEmpty) return;
    final nextAttempt = candidates
        .map(_nextAttemptAt)
        .reduce((left, right) => left.isBefore(right) ? left : right);
    final delay = ignoreBackoff || !nextAttempt.isAfter(now)
        ? Duration.zero
        : nextAttempt.difference(now);
    _backgroundRetryTimer = Timer(
      delay,
      () => unawaited(_drainNextBackgroundStrategy(
        ignoreBackoff: ignoreBackoff,
      )),
    );
  }

  Future<void> _drainNextBackgroundStrategy({
    required bool ignoreBackoff,
  }) async {
    if (_networkBusy) return;
    await _writeTail;
    final accountId = state.accountId;
    if (accountId == null) return;
    final activeStrategyId = state.strategyPublicId;
    final now = DateTime.now();
    final candidates = _recordsByStorageKey.values
        .where((record) =>
            record.accountId == accountId &&
            record.strategyPublicId != activeStrategyId &&
            (record.status == DurableOutboxStatus.queued ||
                record.status == DurableOutboxStatus.inFlight) &&
            (ignoreBackoff || !_nextAttemptAt(record).isAfter(now)))
        .toList(growable: false)
      ..sort((left, right) => left.updatedAt.compareTo(right.updatedAt));
    if (candidates.isEmpty) {
      _scheduleBackgroundDrain();
      return;
    }
    await _flushStrategy(
      accountId: accountId,
      strategyPublicId: candidates.first.strategyPublicId,
      isBackground: true,
      ignoreBackoff: ignoreBackoff,
    );
  }

  DateTime _nextAttemptAt(DurableOutboxRecord record) {
    final lastAttemptAt = record.pending.lastAttemptAt;
    if (lastAttemptAt == null || record.status == DurableOutboxStatus.inFlight) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
    final exponent = record.pending.attempts.clamp(0, 6);
    return lastAttemptAt.add(
      Duration(milliseconds: 300 * (1 << exponent)),
    );
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
