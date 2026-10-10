import 'dart:async';
import 'dart:developer';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/collab/cloud_sync_error_message.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/field_merge.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/client_upgrade_required_provider.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
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
    this.deletedStrategies = const <String, int>{},
  });

  final String? accountId;

  /// Work that can still reach the server, by strategy.
  final Map<String, StrategyOutboxSummary> strategies;

  /// Unsent changes to strategies the server no longer has, counted by
  /// strategy. They wait for the user to discard them and never count as
  /// work, syncing, or attention for the strategies that still exist.
  final Map<String, int> deletedStrategies;

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

  /// A write in this process has not been verified. Persisted, unreadable
  /// records are reported separately by [loadIssues].
  final bool hasDurabilityFailure;
  final bool isFlushing;
  final String? lastError;
  final DateTime? lastFlushAt;
  final List<OpAck> lastAcks;
  final List<AckedEntityIntent> lastAckBatch;
  final AccountStrategyOutboxSummary accountOutbox;

  bool get needsAttention =>
      loadIssues.isNotEmpty ||
      hasDurabilityFailure ||
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
      hasDurabilityFailure: hasDurabilityFailure ?? this.hasDurabilityFailure,
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
  static const Duration _busyBackgroundRetryDelay = Duration(seconds: 1);
  Timer? _debounceTimer;
  Timer? _retryTimer;
  Timer? _backgroundRetryTimer;
  int _offlineRetryCount = 0;
  bool _networkBusy = false;
  ({String accountId, String strategyPublicId})? _drainingStrategy;
  bool _isDisposed = false;
  late DurableStrategyOutboxStore _store;
  late Map<String, DurableOutboxRecord> _recordsByStorageKey;
  final Set<EntitySyncKey> _awaitingRemoteAdoption = {};

  /// Op IDs of the work the open canvas wrote: queued from its edits since
  /// it was last drawn fresh, or resent in their place. Any other op's ack
  /// is marked restored, since the canvas was drawn without it. Cleared by
  /// [forgetCanvasWork].
  final Set<String> _canvasOpIds = {};
  int _canvasSession = 0;

  /// Op IDs of work made while connected, with no disconnect since: it is
  /// sent as the last write (see StrategyOp.forSend). Work queued across a
  /// disconnect or recovered after a restart is not here, so it carries its
  /// merge's base and cannot silently overwrite a teammate's change made
  /// meanwhile. Cleared whenever the connection drops.
  final Set<String> _liveOpIds = {};

  /// Whether the Convex connection is up, as last reported. False until it
  /// reports, so work made before then is treated as made offline.
  bool _connected = false;

  /// How many times the connection has dropped. Work made while connected
  /// is stamped with it ([liveStamp]) and is live only if it has not moved
  /// on by the time the work is queued.
  int _disconnects = 0;

  /// [syncDesiredOpsForPage]'s default madeLive: judge it as the call is
  /// made. (Real stamps count disconnects, so are never negative.)
  static const _judgeLiveNow = -1;

  /// The stamp for work made now: null while disconnected. A caller that
  /// waits on anything before queueing its work takes this first and passes
  /// it on (syncDesiredOpsForPage's madeLive).
  int? get liveStamp => _connected ? _disconnects : null;

  /// Marks [op] live if it was made while connected ([madeLive], its stamp)
  /// with no disconnect since, and any work it merged in ([from]) was live
  /// too: an edit folded into work that waited offline still carries that
  /// work's earlier changes.
  void _markLive(StrategyOp op, {required int? madeLive, StrategyOp? from}) {
    if (madeLive == null || madeLive != _disconnects || !_connected) return;
    if (from != null && !_liveOpIds.contains(from.opId)) return;
    _liveOpIds.add(op.opId);
  }

  final Set<String> _uncertainOversizedParking = {};
  final Set<String> _uncertainDurableRecords = {};
  final Map<String, DurableOutboxRecord> _uncertainDurableIntents = {};
  String? _uncertainOversizedParkingMessage;
  Future<void> _writeTail = Future<void>.value();

  ConvexStrategyRepository get _repo =>
      ref.read(convexStrategyRepositoryProvider);

  @override
  StrategyOpQueueState build() {
    _isDisposed = false;
    _store = ref.read(durableStrategyOutboxStoreProvider);
    final loaded = _store.load();
    _recordsByStorageKey = {
      for (final record in loaded.records)
        record.storageKey: _retiredAsAttention(_resumedAfterUpgrade(record)),
    };
    ref.onDispose(() {
      _isDisposed = true;
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
      final recovered =
          (previous?.hasAuthIncident ?? false) && !next.hasAuthIncident;
      if (becameReady || recovered) {
        retryCurrentAccount();
      }
    });
    // The server accepts this build again: the work it held goes out.
    ref.listen<bool>(clientUpgradeRequiredProvider, (previous, next) {
      if (previous == true && !next) retryCurrentAccount();
    });
    void connectionIs(bool connected) {
      if (_connected && !connected) _disconnects++;
      _connected = connected;
      if (!connected) _liveOpIds.clear();
    }

    ref.listen<bool>(
      convexConnectionSnapshotProvider,
      (_, next) => connectionIs(next),
      // No client to ask (tests that never connect): offline.
      onError: (_, __) => connectionIs(false),
      fireImmediately: true,
    );
    ref.listen<AsyncValue<bool>>(convexConnectionProvider, (previous, next) {
      if (previous?.valueOrNull != true && next.valueOrNull == true) {
        _scheduleBackgroundDrain(ignoreBackoff: true);
      }
    });
    final session = ref.read(strategyOutboxSessionProvider);
    if (session.accountId != null &&
        loaded.records.any((record) => record.accountId == session.accountId)) {
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
      hasDurabilityFailure: false,
      lastError: loaded.issues.isEmpty
          ? null
          : 'The cloud outbox contains unreadable saved work.',
      accountOutbox: _accountSummary(session.accountId),
    );
  }

  /// [record] waiting in attention when it holds a lineup change in the
  /// cloud format before one row per lineup, whatever state an older build
  /// left it in (queued, paused, refused for another reason). It can never
  /// be sent; in attention it is shown, with its reason, and nothing but the
  /// user's discard removes it: reconciling the canvas's work never touches
  /// attention. Like [_resumedAfterUpgrade], only the copy in memory changes.
  static DurableOutboxRecord _retiredAsAttention(DurableOutboxRecord record) {
    if (!isRetiredCloudLineupOp(record.pending.op) ||
        (record.status == DurableOutboxStatus.attention &&
            record.lastError == retiredLineupOpMessage)) {
      return record;
    }
    return record.copyWith(
      status: DurableOutboxStatus.attention,
      lastError: retiredLineupOpMessage,
    );
  }

  /// [record] as this build sends it. Work a build the server refused kept
  /// failing through no fault of its own, and may have been paused for it;
  /// it goes back in the queue with no failures counted. Only the copy in
  /// memory changes: the next write of the record saves it, and until then
  /// every start resumes it again.
  static DurableOutboxRecord _resumedAfterUpgrade(DurableOutboxRecord record) {
    if (!isClientUpgradeRequiredReason(record.lastError) ||
        (record.status != DurableOutboxStatus.paused &&
            record.status != DurableOutboxStatus.queued)) {
      return record;
    }
    return record.copyWith(
      status: DurableOutboxStatus.queued,
      pending: PendingOp(
        op: record.pending.op,
        clientId: record.pending.clientId,
      ),
      clearError: true,
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
          if (cloudOperationExceedsPolicy(record.pending.op)) {
            attention[record.entityKey] = intent;
          } else {
            queued[record.entityKey] = intent;
          }
        case DurableOutboxStatus.inFlight:
          if (cloudOperationExceedsPolicy(record.pending.op)) {
            attention[record.entityKey] = intent;
          } else if (_drainingStrategy ==
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
          if (cloudOperationExceedsPolicy(record.pending.op)) {
            attention[record.entityKey] = intent;
          } else {
            paused[record.entityKey] = intent;
          }
        case DurableOutboxStatus.attention:
          attention[record.entityKey] = intent;
      }
    }
    for (final record in _uncertainDurableIntents.values.where((record) =>
        record.accountId == accountId &&
        record.strategyPublicId == strategyPublicId)) {
      attention[record.entityKey] = QueuedEntityIntent(
        entityKey: record.entityKey,
        pending: record.pending,
      );
      queued.remove(record.entityKey);
      inFlight.remove(record.entityKey);
      paused.remove(record.entityKey);
      final successor = record.successorPending;
      if (successor != null) {
        successors[record.entityKey] = QueuedEntityIntent(
          entityKey: record.entityKey,
          pending: successor,
        );
      }
    }
    final clientId =
        matching.firstOrNull?.pending.clientId ?? const Uuid().v4();
    final hasDurabilityFailure = _hasDurabilityFailureForAccount(accountId);
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
      hasDurabilityFailure: hasDurabilityFailure,
      lastError: hasDurabilityFailure
          ? (_uncertainOversizedParkingMessage ??
              'Cloud work could not be verified in the durable outbox.')
          : _loadedAttentionMessage(
              loadIssues: state.loadIssues,
              paused: paused,
              attention: attention,
              accountId: accountId,
              strategyPublicId: strategyPublicId,
            ),
      accountOutbox: _accountSummary(accountId),
    );
    if (queued.isNotEmpty && inFlight.isEmpty) {
      _scheduleFlush(flushImmediately: true);
    }
    _scheduleBackgroundDrain(ignoreBackoff: true);
  }

  /// The canvas dropped everything it drew and is drawn fresh from the
  /// server (a strategy opened or left, local ones included): no work
  /// already queued is on it any more, so every ack from here on is marked
  /// restored until the canvas queues new work.
  void forgetCanvasWork() {
    _canvasSession++;
    _canvasOpIds.clear();
  }

  /// How many op IDs are remembered as the canvas's work; for tests.
  int get canvasWorkCount => _canvasOpIds.length;

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
    final canvasSession = _canvasSession;
    final madeLive = liveStamp;
    return _serializeWrite(() => _syncDesiredLocked(
          keys: <EntitySyncKey>{entityKey},
          desiredOps: <EntitySyncKey, StrategyOp?>{entityKey: desiredOp},
          flushImmediately: flushImmediately,
          canvasSession: canvasSession,
          madeLive: madeLive,
        ));
  }

  Future<void> syncDesiredOpsForPage({
    required String pageId,
    required Map<EntitySyncKey, StrategyOp> desiredOpsByEntityKey,
    bool clearMissing = true,
    bool flushImmediately = false,
    int? madeLive = _judgeLiveNow,
  }) {
    final canvasSession = _canvasSession;
    // Whether this work is made live is judged now, as it is made, not when
    // its turn to be written comes, unless the caller judged it earlier
    // (null: made offline).
    if (madeLive == _judgeLiveNow) madeLive = liveStamp;
    // A desired op the queue already holds is work kept as it is (live sync
    // keeps recovered work this way), not a new edit. Read now: by the time
    // this write runs it may have landed and left the queue.
    final heldOpIds = {for (final pending in state.pending) pending.op.opId};
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
        canvasSession: canvasSession,
        heldOpIds: heldOpIds,
        madeLive: madeLive,
      );
    });
  }

  /// [canvasSession] is the canvas's session when the desired ops were
  /// asked for: ops made from them are the canvas's work only if it has not
  /// been drawn fresh since. A desired op in [heldOpIds] was already queued
  /// then, so it is not the canvas's work; if it has landed or been
  /// replaced since, whatever the queue now holds for its entity is left as
  /// it is. [madeLive] is the live stamp the work was made with (see
  /// [_markLive]).
  Future<void> _syncDesiredLocked({
    required Set<EntitySyncKey> keys,
    required Map<EntitySyncKey, StrategyOp?> desiredOps,
    required bool flushImmediately,
    required int canvasSession,
    required int? madeLive,
    Set<String> heldOpIds = const {},
  }) async {
    void writtenByCanvas(
      PendingOp pending,
      StrategyOp desired, {
      StrategyOp? from,
    }) {
      // Work the queue already held (recovered after a restart, say) is
      // not newly made, live or not.
      if (!heldOpIds.contains(desired.opId)) {
        _markLive(pending.op, madeLive: madeLive, from: from);
      }
      if (canvasSession == _canvasSession &&
          !heldOpIds.contains(desired.opId)) {
        _canvasOpIds.add(pending.op.opId);
      }
    }

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
        // Kept work that has landed or been replaced since is not written
        // again.
        if (desired != null &&
            heldOpIds.contains(desired.opId) &&
            ![
              existing?.pending,
              inFlightIntent?.pending,
              successorIntent?.pending,
              pausedIntent?.pending,
              attentionIntent?.pending,
            ].any((pending) => pending?.op.opId == desired.opId)) {
          continue;
        }

        // A rejected op remains the durable authority until the user
        // explicitly retries it. Reconciliation may update its successor, but
        // it must never make rejected work eligible for an automatic flush.
        if (attentionIntent != null) {
          if (desired == null) continue;
          final storageKey = DurableOutboxRecord.createStorageKey(
            accountId: accountId,
            strategyPublicId: strategyPublicId,
            entityKey: key,
          );
          final current =
              _recordForActiveKey(key) ?? _uncertainDurableIntents[storageKey];
          if (current == null) {
            throw StateError('Durable attention record is missing for $key.');
          }
          if (_sameIntent(attentionIntent.pending.op, desired)) {
            final hasUncertainDurableRecord =
                _uncertainDurableRecords.contains(storageKey);
            if (successorIntent != null || hasUncertainDurableRecord) {
              final recoveredOversizedParking =
                  _uncertainOversizedParking.contains(storageKey);
              final isOversized =
                  cloudOperationExceedsPolicy(current.pending.op);
              final requeues = hasUncertainDurableRecord && !isOversized;
              // Dropping only the successor leaves the refused change as it
              // was, so it keeps the server's reason for refusing it.
              await _putRecord(current.copyWith(
                status: isOversized
                    ? DurableOutboxStatus.attention
                    : (requeues ? DurableOutboxStatus.queued : current.status),
                clearSuccessorPending: true,
                updatedAt: DateTime.now(),
                lastError: isOversized ? cloudOperationTooLargeMessage : null,
                clearError: requeues ||
                    current.lastError == cloudOperationTooLargeMessage,
              ));
              if (recoveredOversizedParking) {
                _uncertainOversizedParking.remove(storageKey);
                if (_uncertainOversizedParking.isEmpty) {
                  _uncertainOversizedParkingMessage = null;
                }
              }
              successors.remove(key);
              if (hasUncertainDurableRecord && !isOversized) {
                attention.remove(key);
                queued[key] = attentionIntent;
              }
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
          writtenByCanvas(pending, desired, from: successorIntent?.pending.op);
          final recoveredOversizedParking =
              _uncertainOversizedParking.contains(current.storageKey);
          await _putRecord(current.copyWith(
            status: DurableOutboxStatus.attention,
            successorPending: pending,
            updatedAt: DateTime.now(),
            lastError: recoveredOversizedParking
                ? cloudOperationTooLargeMessage
                : null,
          ));
          if (recoveredOversizedParking) {
            _uncertainOversizedParking.remove(current.storageKey);
            if (_uncertainOversizedParking.isEmpty) {
              _uncertainOversizedParkingMessage = null;
            }
          }
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
          final predecessor = inFlightIntent.pending.op;
          final pending = PendingOp(
            op: _asSuccessorOf(
              successorIntent == null
                  ? desired
                  : _mergeQueuedIntent(successorIntent.pending.op, desired) ??
                      desired,
              predecessor,
              drawn: _canvasOpIds.contains(predecessor.opId),
            ),
            clientId: successorIntent?.pending.clientId ?? state.clientId!,
          );
          writtenByCanvas(pending, desired, from: successorIntent?.pending.op);
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
            op: _asSuccessorOf(
              _mergeQueuedIntent(successorIntent.pending.op, desired) ??
                  desired,
              existing.pending.op,
              drawn: _canvasOpIds.contains(existing.pending.op.opId),
            ),
            clientId: successorIntent.pending.clientId,
          );
          writtenByCanvas(pending, desired, from: successorIntent.pending.op);
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
        writtenByCanvas(pending, desired, from: base?.pending.op);
        final record = _recordFor(
          key: key,
          pending: pending,
          status: cloudOperationExceedsPolicy(pending.op)
              ? DurableOutboxStatus.attention
              : DurableOutboxStatus.queued,
          lastError: cloudOperationExceedsPolicy(pending.op)
              ? cloudOperationTooLargeMessage
              : null,
        );
        await _putRecord(record);
        final intent = QueuedEntityIntent(entityKey: key, pending: pending);
        if (record.status == DurableOutboxStatus.attention) {
          attention[key] = intent;
          queued.remove(key);
        } else {
          queued[key] = intent;
          attention.remove(key);
        }
        paused.remove(key);
        changed = true;
      }
    } catch (error, stackTrace) {
      _recordPersistenceFailure(error, stackTrace);
      return;
    }
    if (!changed) return;
    _pruneCanvasOpIds();
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
      hasDurabilityFailure: _hasDurabilityFailureForCurrentAccount,
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
      final attention = Map<EntitySyncKey, QueuedEntityIntent>.from(
        state.attentionByEntityKey,
      );
      try {
        for (final entry in state.pausedByEntityKey.entries) {
          final pending = PendingOp(
            op: entry.value.pending.op,
            clientId: entry.value.pending.clientId,
          );
          final isOversized = cloudOperationExceedsPolicy(pending.op);
          await _putRecord(_recordFor(
            key: entry.key,
            pending: pending,
            status: isOversized
                ? DurableOutboxStatus.attention
                : DurableOutboxStatus.queued,
            lastError: isOversized ? cloudOperationTooLargeMessage : null,
          ));
          final intent =
              QueuedEntityIntent(entityKey: entry.key, pending: pending);
          if (isOversized) {
            attention[entry.key] = intent;
            queued.remove(entry.key);
          } else {
            queued[entry.key] = intent;
          }
        }
      } catch (error, stackTrace) {
        _recordPersistenceFailure(error, stackTrace);
        return;
      }
      state = state.copyWith(
        queuedByEntityKey: queued,
        pausedByEntityKey: const <EntitySyncKey, QueuedEntityIntent>{},
        attentionByEntityKey: attention,
        hasDurabilityFailure: _hasDurabilityFailureForCurrentAccount,
        clearError: attention.isEmpty && state.loadIssues.isEmpty,
      );
      _scheduleFlush(flushImmediately: flushImmediately);
    });
  }

  /// Rebases server-rejected intents only after an explicit user action.
  ///
  /// The server revision is stored with the durable attention record, so the
  /// same recovery remains available after an app restart. Ordinary page
  /// reconciliation never removes these records.
  Future<void> retryRejected({bool flushImmediately = true}) =>
      _retryAttention(flushImmediately: flushImmediately);

  /// Sends again, as they were, the changes to [pageId] the server refused
  /// while the page was in its trash: it has just been restored. Each goes
  /// under a new op id, since the server answers a known one as it did
  /// before.
  Future<void> retryRestoredPage(String pageId) => retryRestoredPages({pageId});

  /// Re-sends the edits refused because their page was deleted, for the pages
  /// in [livePageIds], which are live again (restored here or by anyone).
  Future<void> retryRestoredPages(Set<String> livePageIds) => _retryAttention(
        flushImmediately: true,
        only: (key, record) =>
            livePageIds.contains(key.pageId) &&
            record?.lastError == pageDeletedMessage,
      );

  /// Retries the attention records [only] accepts, or all of them.
  Future<void> _retryAttention({
    required bool flushImmediately,
    bool Function(EntitySyncKey key, DurableOutboxRecord? record)? only,
  }) {
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
          if (only != null && !only(entry.key, record)) continue;
          final rejected = entry.value.pending;
          final rejectedOp = rejected.op;
          final successor = record?.successorPending;
          final retryOp = successor?.op ?? rejectedOp;
          // No server takes a lineup change in the old cloud format; sending
          // it again would only bring it back here.
          if (isRetiredCloudLineupOp(retryOp)) continue;
          final isPayloadPolicyAttention =
              record?.lastError == cloudOperationTooLargeMessage ||
                  cloudOperationExceedsPolicy(rejectedOp);
          // Nothing moved on the server: a change to a page in the trash is
          // re-sent as it was once the page is restored.
          final isOnDeletedPage = record?.lastError == pageDeletedMessage;
          final retriesAsSent = isPayloadPolicyAttention || isOnDeletedPage;
          final retryRevision =
              record?.latestServerRevision ?? rejectedOp.expectedRevision;
          if (!retriesAsSent && retryRevision == null) continue;
          final isTombstoneRestore =
              (retryOp is ElementAddOp || retryOp is LineupAddOp) &&
                  (record?.lastError == 'missing_expected_revision' ||
                      record?.lastError == 'revision_mismatch');
          // A teammate deleted what this change edits. Keeping mine brings
          // it back as the user has it: an add over the tombstone.
          final restoresDeleted =
              record?.lastError == OpRejectionReason.deleted.wireName;
          final StrategyOp rebasedOp;
          if (retriesAsSent) {
            rebasedOp = retryOp.withOpId(const Uuid().v4());
          } else if (restoresDeleted) {
            final restore = _restoreOp(retryOp, retryRevision!);
            if (restore == null) continue;
            rebasedOp = restore;
          } else {
            rebasedOp = _keptMine(
              _rebaseRejectedOp(
                retryOp,
                retryRevision!,
                preserveAdd: isTombstoneRestore,
              ),
              refusal: record?.lastError,
              serverHas: record?.latestServerPayload,
            );
          }
          _keepCanvasWritten(retryOp, rebasedOp);
          final pending = PendingOp(
            op: rebasedOp,
            clientId: successor?.clientId ?? rejected.clientId,
          );
          final isRetryOversized = cloudOperationExceedsPolicy(pending.op);
          await _putRecord(_recordFor(
            key: entry.key,
            pending: pending,
            status: isRetryOversized
                ? DurableOutboxStatus.attention
                : DurableOutboxStatus.queued,
            clearSuccessorPending: true,
            lastError: isRetryOversized ? cloudOperationTooLargeMessage : null,
          ));
          _uncertainOversizedParking.remove(
            DurableOutboxRecord.createStorageKey(
              accountId: state.accountId!,
              strategyPublicId: state.strategyPublicId!,
              entityKey: entry.key,
            ),
          );
          final intent = QueuedEntityIntent(
            entityKey: entry.key,
            pending: pending,
          );
          if (isRetryOversized) {
            attention[entry.key] = intent;
            queued.remove(entry.key);
          } else {
            queued[entry.key] = intent;
            attention.remove(entry.key);
          }
          successors.remove(entry.key);
          changed = true;
        }
      } catch (error, stackTrace) {
        _recordPersistenceFailure(error, stackTrace);
        return;
      }
      if (!changed) {
        if (only != null) return;
        // Old-format lineup changes are skipped on purpose, and keep their
        // own reason.
        final onlyRetired = attention.values.every(
          (intent) => isRetiredCloudLineupOp(intent.pending.op),
        );
        // Changes a teammate's delete refused that hold nothing to bring
        // the item back with.
        final cannotRestore = attention.keys.any(
          (key) =>
              _recordForActiveKey(key)?.lastError ==
              OpRejectionReason.deleted.wireName,
        );
        state = state.copyWith(
          lastError: onlyRetired
              ? _loadedAttentionMessage(
                  loadIssues: state.loadIssues,
                  paused: state.pausedByEntityKey,
                  attention: attention,
                )
              : cannotRestore
                  ? teammateDeletedCannotRestoreMessage
                  : 'Some retained cloud work cannot be retried '
                      'automatically because the server has no matching '
                      'revision.',
        );
        return;
      }
      if (_uncertainOversizedParking.isEmpty) {
        _uncertainOversizedParkingMessage = null;
      }
      _pruneCanvasOpIds();
      final attentionMessage = _loadedAttentionMessage(
        loadIssues: state.loadIssues,
        paused: state.pausedByEntityKey,
        attention: attention,
      );
      state = state.copyWith(
        queuedByEntityKey: queued,
        attentionByEntityKey: attention,
        successorByEntityKey: successors,
        hasDurabilityFailure: _hasDurabilityFailureForCurrentAccount,
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
  ///
  /// Given [onlyIf] (the refused op id and successor op id of each key, as
  /// the user last saw them), a key whose waiting work has changed since is
  /// left as it is: the user chose to discard that work, not a newer edit.
  Future<Set<EntitySyncKey>> discardRejected(
    Set<EntitySyncKey> entityKeys, {
    Map<EntitySyncKey, (String, String?)>? onlyIf,
  }) =>
      _dropAttention(entityKeys, adoptRemote: true, onlyIf: onlyIf);

  /// Whether the server refused [key]'s waiting work because a teammate
  /// deleted what it edits (rejection reason `deleted`).
  bool refusedAsDeleted(EntitySyncKey key) =>
      _recordForActiveKey(key)?.lastError == OpRejectionReason.deleted.wireName;

  /// Drops the refused work of entities the user has since deleted on the
  /// canvas, when the server refused it because a teammate deleted them
  /// ([refusedAsDeleted]). Both sides agree they are gone, so nothing is
  /// left to keep, and Keep mine must not bring them back. Work refused for
  /// any other reason stays: only that refusal says the server deleted the
  /// item, rather than never having it or holding it elsewhere. Unlike
  /// [discardRejected] the canvas is already the truth: there is nothing to
  /// adopt.
  Future<Set<EntitySyncKey>> settleAttention(Set<EntitySyncKey> entityKeys) =>
      _dropAttention(
        {
          for (final key in entityKeys)
            if (refusedAsDeleted(key)) key
        },
        adoptRemote: false,
      );

  Future<Set<EntitySyncKey>> _dropAttention(
    Set<EntitySyncKey> entityKeys, {
    required bool adoptRemote,
    Map<EntitySyncKey, (String, String?)>? onlyIf,
  }) {
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
        final accountId = state.accountId;
        final strategyPublicId = state.strategyPublicId;
        if (rejected == null || accountId == null || strategyPublicId == null) {
          continue;
        }
        if (onlyIf != null &&
            onlyIf[key] !=
                (
                  rejected.pending.op.opId,
                  successors[key]?.pending.op.opId,
                )) {
          continue;
        }
        final storageKey = DurableOutboxRecord.createStorageKey(
          accountId: accountId,
          strategyPublicId: strategyPublicId,
          entityKey: key,
        );
        final hasUncertainParking =
            _uncertainOversizedParking.contains(storageKey);
        final hasUncertainDurableRecord =
            _uncertainDurableRecords.contains(storageKey);
        final record = _recordForActiveKey(key);
        final hasMatchingAttentionRecord = record != null &&
            (record.status == DurableOutboxStatus.attention ||
                cloudOperationExceedsPolicy(record.pending.op)) &&
            record.pending.op.opId == rejected.pending.op.opId;
        if (!hasUncertainParking &&
            !hasUncertainDurableRecord &&
            !hasMatchingAttentionRecord) {
          continue;
        }
        try {
          await _removeRecordByStorageKey(storageKey);
          _uncertainOversizedParking.remove(storageKey);
          attention.remove(key);
          successors.remove(key);
          if (adoptRemote) _awaitingRemoteAdoption.add(key);
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
      if (_uncertainOversizedParking.isEmpty) {
        _uncertainOversizedParkingMessage = null;
      }
      _pruneCanvasOpIds();
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
        hasDurabilityFailure: _hasDurabilityFailureForCurrentAccount,
        lastError: errorMessage,
        clearError: errorMessage == null,
      );
      return Set<EntitySyncKey>.unmodifiable(discarded);
    });
  }

  void completeRemoteAdoption(Set<EntitySyncKey> entityKeys) {
    _awaitingRemoteAdoption.removeAll(entityKeys);
  }

  Future<bool> _parkOversizedQueuedOps() async {
    if (_hasUncertainParkingForActiveStrategy) return false;
    final oversized = state.queuedByEntityKey.entries
        .where((entry) => cloudOperationExceedsPolicy(entry.value.pending.op))
        .toList(growable: false);
    if (oversized.isEmpty) return true;

    final queued = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.queuedByEntityKey,
    );
    final attention = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.attentionByEntityKey,
    );
    Object? persistenceError;
    StackTrace? persistenceStackTrace;
    for (final entry in oversized) {
      final record = _recordForActiveKey(entry.key);
      if (record == null ||
          record.pending.op.opId != entry.value.pending.op.opId) {
        persistenceError ??=
            StateError('Durable queued record is missing for ${entry.key}.');
        queued.remove(entry.key);
        attention[entry.key] = entry.value;
        _uncertainOversizedParking.add(
          DurableOutboxRecord.createStorageKey(
            accountId: state.accountId!,
            strategyPublicId: state.strategyPublicId!,
            entityKey: entry.key,
          ),
        );
        continue;
      }
      // Keep an already-durable queued record untouched. The in-memory view
      // and restart loader both classify it as attention, so parking never
      // risks destroying the only recoverable copy with an overwrite.
      queued.remove(entry.key);
      attention[entry.key] = entry.value;
    }
    if (persistenceError != null) {
      log(
        'Durable outbox persistence failed: $persistenceError',
        name: 'strategy_outbox',
        error: persistenceError,
        stackTrace: persistenceStackTrace,
      );
      _debounceTimer?.cancel();
      _debounceTimer = null;
      _retryTimer?.cancel();
      _retryTimer = null;
      _uncertainOversizedParkingMessage =
          'Cloud work could not be verified in the durable outbox. '
          'Nothing was sent. The change still needs attention: '
          '$persistenceError';
    }
    final attentionMessage = _loadedAttentionMessage(
      loadIssues: state.loadIssues,
      paused: state.pausedByEntityKey,
      attention: attention,
    );
    state = state.copyWith(
      queuedByEntityKey: queued,
      attentionByEntityKey: attention,
      hasDurabilityFailure: _hasDurabilityFailureForCurrentAccount,
      lastError: persistenceError == null
          ? attentionMessage
          : _uncertainOversizedParkingMessage,
      clearError: persistenceError == null && attentionMessage == null,
    );
    return persistenceError == null;
  }

  Future<void> flushNow() async {
    await _writeTail;
    if (_isDisposed || _networkBusy) return;
    final accountId = state.accountId;
    final strategyPublicId = state.strategyPublicId;
    if (accountId == null ||
        strategyPublicId == null ||
        state.queuedByEntityKey.isEmpty) {
      return;
    }

    if (!await _parkOversizedQueuedOps() || _isDisposed) return;
    if (state.queuedByEntityKey.isEmpty) return;

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
    if (_isDisposed || _networkBusy) return;

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
    // The server refuses this build, so nothing sent would land. The work
    // waits, with no failure counted, for the reload or update that brings
    // a build it accepts.
    if (ref.read(clientUpgradeRequiredProvider)) {
      if (!isBackground && _isActive(accountId, strategyPublicId)) {
        state = state.copyWith(lastError: clientUpgradeRequiredQueueError);
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
        if (state.lastError != message) {
          AppErrorReporter.reportWarning(
            'Cloud sync is holding changes for strategy $strategyPublicId: '
            '$message',
            source: 'cloud_sync.op_queue',
          );
        }
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
    if (_isDisposed) {
      _finishNetworkLane();
      return;
    }
    // The claim awaited durable writes, and the account may have signed out
    // or changed meanwhile. The batch belongs to the account that queued it,
    // so it goes back to that account's queue, untouched, to send once it is
    // signed in again.
    if (!_canSendAs(accountId)) {
      await _releaseClaimedRecords(batch);
      _finishNetworkLane();
      _scheduleBackgroundDrain();
      return;
    }
    final batchClientId = batch.first.pending.clientId;
    final isActiveStrategy = _isActive(accountId, strategyPublicId);
    _refreshActiveQueueView(
      isFlushing: isActiveStrategy,
      clearError: isActiveStrategy,
    );

    try {
      _retryTimer?.cancel();
      _retryTimer = null;
      _offlineRetryCount = 0;
      final acks = await _repo.applyBatch(
        strategyPublicId: strategyPublicId,
        clientId: batchClientId,
        ops: [
          for (final record in batch)
            record.pending.op.forSend(
              live: _liveOpIds.contains(record.pending.op.opId),
            ),
        ],
        // The transport can deliver this after a later sign-in (it resends
        // pending requests on reconnect), so the server checks the batch's
        // own account, not whoever is signed in then.
        accountSubject: batch.first.accountId,
      );
      await _applyAcksForRecords(batch, acks);
      batchSucceeded = true;
    } catch (error, stackTrace) {
      // applyBatch raises NOT_FOUND only for the strategy itself (a missing
      // page or element is a per-op result); the shell query confirms it is
      // gone. Retrying could never succeed.
      final strategyDeleted = isTypedConvexNotFoundError(error) &&
          await _strategyIsConfirmedDeleted(strategyPublicId);
      if (strategyDeleted) {
        await _resolveDeletedStrategy(
          accountId: accountId,
          strategyPublicId: strategyPublicId,
        );
      } else {
        final upgradeRequired =
            ref.read(clientUpgradeRequiredProvider.notifier).noteError(error);
        if (isConvexUnauthenticatedError(error)) {
          unawaited(ref.read(authProvider.notifier).reportConvexUnauthenticated(
                source: 'strategy_op_queue:flush',
                error: error,
                stackTrace: stackTrace,
              ));
        } else {
          AppErrorReporter.reportWarning(
            'Cloud sync could not send ${batch.length} change(s) for strategy '
            '$strategyPublicId',
            source: 'cloud_sync.op_queue',
            error: redactSyncDiagnosticText(error),
            stackTrace: stackTrace,
          );
        }
        await _restoreRecordsAfterFailure(
          batch,
          lastError:
              upgradeRequired ? clientUpgradeRequiredQueueError : '$error',
          countsAsFailure: !upgradeRequired,
        );
      }
    } finally {
      _finishNetworkLane();
    }

    if (!_isDisposed) {
      if (state.queuedByEntityKey.isNotEmpty &&
          (isBackground || batchSucceeded)) {
        unawaited(flushNow());
      }
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
              !_uncertainDurableRecords.contains(record.storageKey) &&
              !cloudOperationExceedsPolicy(record.pending.op) &&
              (ignoreBackoff || !_nextAttemptAt(record).isAfter(now)))
          .toList(growable: false);
      if (candidates.isEmpty) return const <DurableOutboxRecord>[];
      final selected = <DurableOutboxRecord>[];
      final batchClientId = candidates.first.pending.clientId;
      for (final candidate in candidates) {
        if (candidate.pending.clientId != batchClientId) continue;
        if (selected.length >= _maxBatchSize) break;
        final nextSelection = <DurableOutboxRecord>[...selected, candidate];
        final byteSize = serializedCloudBatchUtf8Bytes(
          strategyPublicId: strategyPublicId,
          clientId: batchClientId,
          ops: nextSelection.map((record) => record.pending.op),
        );
        if (byteSize > maxCloudBatchBytes) break;
        selected.add(candidate);
      }
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
    for (final ack in acks) {
      final sent = byOpId[ack.opId];
      if (sent == null) continue;
      final current = _recordsByStorageKey[sent.storageKey];
      if (current?.pending.op.opId != ack.opId) continue;
      final successor = current!.successorPending;
      // Only an accepted predecessor establishes a revision for automatic
      // promotion. A rejected predecessor leaves both intents in attention.
      final successorRevision = ack.appliedRevision;
      if (successor != null && ack.isAck && successorRevision != null) {
        final predecessorCreatedEntity =
            sent.pending.op is ElementAddOp || sent.pending.op is LineupAddOp;
        final promoted = PendingOp(
          op: _onLandedPredecessor(
            _rebaseRejectedOp(
              successor.op,
              successorRevision,
              preserveAdd: !predecessorCreatedEntity,
            ),
            original: successor.op,
            predecessor: sent.pending.op,
          ),
          clientId: successor.clientId,
        );
        _keepCanvasWritten(successor.op, promoted.op, keepLive: true);
        final isPromotedOversized = cloudOperationExceedsPolicy(promoted.op);
        await _putRecord(current.copyWith(
          pending: promoted,
          status: isPromotedOversized
              ? DurableOutboxStatus.attention
              : DurableOutboxStatus.queued,
          updatedAt: DateTime.now(),
          clearSuccessorPending: true,
          lastError: isPromotedOversized ? cloudOperationTooLargeMessage : null,
          clearError: !isPromotedOversized,
          clearLatestServerRevision: true,
        ));
      } else if (successor != null) {
        final retained = current.copyWith(
          status: DurableOutboxStatus.attention,
          updatedAt: DateTime.now(),
          lastError: ack.reason ??
              'The final change is waiting for conflict resolution.',
          latestServerRevision: ack.latestRevision,
          latestServerPayload: ack.latestPayload,
        );
        await _putRecord(retained);
      } else if (ack.isAck) {
        await _removeRecordByStorageKeyIfCurrent(sent.storageKey, ack.opId);
      } else {
        AppErrorReporter.reportWarning(
          'The server rejected change ${ack.opId} for strategy '
          '${sent.strategyPublicId}',
          source: 'cloud_sync.op_queue',
          error: redactSyncDiagnosticText(
            ack.reason ?? 'no reason given',
          ),
        );
        final rejected = current.copyWith(
          status: DurableOutboxStatus.attention,
          updatedAt: DateTime.now(),
          lastError: ack.reason ?? 'The server rejected this change.',
          latestServerRevision: ack.latestRevision,
          latestServerPayload: ack.latestPayload,
        );
        await _putRecord(rejected);
      }
    }
    // Judged once the records are stored: the canvas may have been drawn
    // fresh meanwhile, and then none of this is on it.
    final acked = [
      for (final ack in acks)
        if (byOpId[ack.opId] case final sent?)
          AckedEntityIntent(
            entityKey: sent.entityKey,
            op: sent.pending.op,
            ack: ack,
            restored: !_canvasOpIds.contains(ack.opId),
          ),
    ];
    _pruneCanvasOpIds();
    if (_isDisposed) return;
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

  /// Whether the server confirms [strategyPublicId] is gone. Anything short
  /// of a confirmation (offline, auth) is false, and the send is retried as
  /// an ordinary failure.
  Future<bool> _strategyIsConfirmedDeleted(String strategyPublicId) async {
    try {
      return await _repo.strategyIsDeleted(strategyPublicId);
    } catch (_) {
      return false;
    }
  }

  /// Settles every outbox record of a strategy the server no longer has.
  /// If none of its changes carries anything the user authored (only
  /// removals and reorders of a strategy that is gone), they are dropped
  /// with a warning. Otherwise they stay on this device marked
  /// [cloudStrategyDeletedMessage], never retried, until the user discards
  /// them from the library.
  Future<void> _resolveDeletedStrategy({
    required String accountId,
    required String strategyPublicId,
  }) {
    return _serializeWrite(() async {
      final records = _recordsByStorageKey.values
          .where((record) =>
              record.accountId == accountId &&
              record.strategyPublicId == strategyPublicId)
          .toList(growable: false);
      final keepsAuthoredWork = records.any(
        (record) =>
            _carriesAuthoredContent(record.pending.op) ||
            (record.successorPending != null &&
                _carriesAuthoredContent(record.successorPending!.op)),
      );
      try {
        for (final record in records) {
          if (keepsAuthoredWork) {
            await _putRecord(record.copyWith(
              status: DurableOutboxStatus.attention,
              updatedAt: DateTime.now(),
              lastError: cloudStrategyDeletedMessage,
            ));
          } else {
            await _removeRecordByStorageKey(record.storageKey);
          }
        }
      } catch (error, stackTrace) {
        _recordPersistenceFailure(error, stackTrace);
        return;
      } finally {
        _pruneCanvasOpIds();
      }
      AppErrorReporter.reportWarning(
        keepsAuthoredWork
            ? 'Strategy $strategyPublicId was deleted on the server; '
                '${records.length} unsent change(s) are kept on this device '
                'until discarded.'
            : 'Strategy $strategyPublicId was deleted on the server; dropped '
                '${records.length} unsent removal(s) that had nothing left to '
                'remove.',
        source: 'cloud_sync.op_queue',
      );
      _refreshActiveQueueView(isFlushing: false);
    });
  }

  /// Drops every outbox record of [strategyPublicId] for the current
  /// account: a strategy the server no longer has, discarded by the user or
  /// deleted by them on this device.
  Future<void> discardDeletedStrategy(String strategyPublicId) {
    return _serializeWrite(() async {
      final accountId = state.accountId;
      if (accountId == null) return;
      final storageKeys = _recordsByStorageKey.values
          .where((record) =>
              record.accountId == accountId &&
              record.strategyPublicId == strategyPublicId)
          .map((record) => record.storageKey)
          .toList(growable: false);
      try {
        for (final storageKey in storageKeys) {
          await _removeRecordByStorageKey(storageKey);
        }
      } catch (error, stackTrace) {
        _recordPersistenceFailure(error, stackTrace);
        return;
      } finally {
        _pruneCanvasOpIds();
      }
      _refreshActiveQueueView();
    });
  }

  /// Drops every outbox record of [pageId] in the active strategy, with any
  /// successor it holds, including work whose first save could not be
  /// verified: work for a page the server no longer has, which the user has
  /// been told cannot be saved. An op in flight stays until the server
  /// answers it; one marked in flight by a send that never finished (the app
  /// closed mid-request) is only waiting to be replayed, and goes. Returns
  /// whether nothing is left for the page.
  Future<bool> discardDeletedPage(String pageId) async {
    await _serializeWrite(() async {
      final accountId = state.accountId;
      final strategyPublicId = state.strategyPublicId;
      if (accountId == null || strategyPublicId == null) return;
      final isSending = _drainingStrategy ==
          (accountId: accountId, strategyPublicId: strategyPublicId);
      final storageKeys = {
        for (final record in [
          ..._recordsByStorageKey.values,
          ..._uncertainDurableIntents.values,
        ])
          if (record.accountId == accountId &&
              record.strategyPublicId == strategyPublicId &&
              record.entityKey.pageId == pageId &&
              !(isSending && record.status == DurableOutboxStatus.inFlight))
            record.storageKey,
      };
      Object? persistenceError;
      for (final storageKey in storageKeys) {
        try {
          await _removeRecordByStorageKey(storageKey);
          _uncertainOversizedParking.remove(storageKey);
        } catch (error, stackTrace) {
          persistenceError = error;
          log(
            'Durable outbox persistence failed: $error',
            name: 'strategy_outbox',
            error: error,
            stackTrace: stackTrace,
          );
          break;
        }
      }
      if (_uncertainOversizedParking.isEmpty) {
        _uncertainOversizedParkingMessage = null;
      }
      _pruneCanvasOpIds();
      // The error shown was about the dropped work or about what remains;
      // what remains says it again.
      _refreshActiveQueueView(
        useProvidedError: true,
        lastError: persistenceError == null
            ? null
            : 'Cloud work could not be removed from the durable outbox: '
                '$persistenceError',
      );
    });
    final left = state;
    return ![
      left.queuedByEntityKey,
      left.inFlightByEntityKey,
      left.successorByEntityKey,
      left.pausedByEntityKey,
      left.attentionByEntityKey,
    ].any((intents) => intents.keys.any((key) => key.pageId == pageId));
  }

  /// Whether [op] carries something the user authored, as opposed to only
  /// removing or reordering. Exhaustive, so a new op type must be placed.
  static bool _carriesAuthoredContent(StrategyOp op) => switch (op) {
        StrategyPatchOp() ||
        PageAddOp() ||
        PagePatchOp() ||
        PageContentPatchOp() ||
        ElementAddOp() ||
        ElementPatchOp() ||
        LineupAddOp() ||
        LineupPatchOp() =>
          true,
        PageDeleteOp() ||
        PageReorderOp() ||
        ElementDeleteOp() ||
        ElementReorderOp() ||
        LineupDeleteOp() ||
        LineupReorderOp() =>
          false,
      };

  /// Whether [accountId] is the account signed in, ready, with no auth
  /// incident: the only time its work may be sent.
  bool _canSendAs(String accountId) {
    final auth = ref.read(authProvider);
    return !auth.hasActiveAuthIncident &&
        auth.user?.id == accountId &&
        auth.isAuthenticated &&
        auth.isConvexUserReady;
  }

  /// Returns a claimed batch that was never sent to its account's queue:
  /// same op ids, no attempt counted.
  Future<void> _releaseClaimedRecords(List<DurableOutboxRecord> batch) {
    return _serializeWrite(() async {
      try {
        for (final claimed in batch) {
          final current = _recordsByStorageKey[claimed.storageKey];
          if (current == null ||
              current.pending.op.opId != claimed.pending.op.opId ||
              current.status != DurableOutboxStatus.inFlight) {
            continue;
          }
          await _putRecord(current.copyWith(
            status: DurableOutboxStatus.queued,
            updatedAt: DateTime.now(),
          ));
        }
      } catch (error, stackTrace) {
        _recordPersistenceFailure(error, stackTrace);
        return;
      }
      _refreshActiveQueueView();
    });
  }

  /// Puts [batch] back in the queue after a send failed. Unless
  /// [countsAsFailure] is false, each record counts a failure, and one that
  /// has failed too often is paused until the user retries it.
  Future<void> _restoreRecordsAfterFailure(
    List<DurableOutboxRecord> batch, {
    required String lastError,
    bool countsAsFailure = true,
  }) {
    return _serializeWrite(
      () => _restoreRecordsAfterFailureLocked(
        batch,
        lastError: lastError,
        countsAsFailure: countsAsFailure,
      ),
    );
  }

  Future<void> _restoreRecordsAfterFailureLocked(
    List<DurableOutboxRecord> batch, {
    required String lastError,
    required bool countsAsFailure,
  }) async {
    // A send that failed is retried later, by when a teammate may have
    // changed the same fields: it goes checked.
    _liveOpIds.removeAll([
      for (final sent in batch) sent.pending.op.opId,
    ]);
    final retrying = <PendingOp>[];
    try {
      for (final sent in batch) {
        final current = _recordsByStorageKey[sent.storageKey];
        if (current == null ||
            current.pending.op.opId != sent.pending.op.opId) {
          continue;
        }
        final pending = countsAsFailure
            ? current.pending.incrementAttempt()
            : current.pending;
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
    if (_isDisposed) return;
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
    try {
      await _store.put(record);
      _recordsByStorageKey[record.storageKey] = record;
      _uncertainDurableRecords.remove(record.storageKey);
      _uncertainDurableIntents.remove(record.storageKey);
    } catch (_) {
      _uncertainDurableRecords.add(record.storageKey);
      _uncertainDurableIntents[record.storageKey] = record;
      if (cloudOperationExceedsPolicy(record.pending.op)) {
        _uncertainOversizedParking.add(record.storageKey);
        _uncertainOversizedParkingMessage =
            'Cloud work could not be verified in the durable outbox. '
            'Nothing was sent.';
      }
      _publishAccountSummary();
      rethrow;
    }
    _publishAccountSummary();
  }

  Future<void> _removeRecordByStorageKey(String storageKey) async {
    try {
      await _store.remove(storageKey);
      _recordsByStorageKey.remove(storageKey);
      _uncertainDurableRecords.remove(storageKey);
      _uncertainDurableIntents.remove(storageKey);
    } catch (_) {
      _uncertainDurableRecords.add(storageKey);
      _publishAccountSummary();
      rethrow;
    }
    _publishAccountSummary();
  }

  Future<void> _removeRecordIfCurrent(
    EntitySyncKey key,
    String opId,
  ) async {
    final record = _recordForActiveKey(key);
    if (record == null || record.pending.op.opId != opId) return;
    await _removeRecordByStorageKey(record.storageKey);
  }

  Future<void> _removeRecordByStorageKeyIfCurrent(
    String storageKey,
    String opId,
  ) async {
    final record = _recordsByStorageKey[storageKey];
    if (record == null || record.pending.op.opId != opId) return;
    await _removeRecordByStorageKey(storageKey);
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
    if (_isDisposed) return;
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
            if (cloudOperationExceedsPolicy(record.pending.op)) {
              attention[record.entityKey] = intent;
            } else {
              queued[record.entityKey] = intent;
            }
          case DurableOutboxStatus.inFlight:
            if (cloudOperationExceedsPolicy(record.pending.op)) {
              attention[record.entityKey] = intent;
            } else if (isActivelyDraining) {
              inFlight[record.entityKey] = InFlightEntityIntent(
                entityKey: record.entityKey,
                pending: record.pending,
                sentAt: record.updatedAt,
              );
            } else {
              queued[record.entityKey] = intent;
            }
          case DurableOutboxStatus.paused:
            if (cloudOperationExceedsPolicy(record.pending.op)) {
              attention[record.entityKey] = intent;
            } else {
              paused[record.entityKey] = intent;
            }
          case DurableOutboxStatus.attention:
            attention[record.entityKey] = intent;
        }
      }
      for (final record in _uncertainDurableIntents.values.where((record) =>
          record.accountId == accountId &&
          record.strategyPublicId == strategyPublicId)) {
        attention[record.entityKey] = QueuedEntityIntent(
          entityKey: record.entityKey,
          pending: record.pending,
        );
        queued.remove(record.entityKey);
        inFlight.remove(record.entityKey);
        paused.remove(record.entityKey);
        final successor = record.successorPending;
        if (successor != null) {
          successors[record.entityKey] = QueuedEntityIntent(
            entityKey: record.entityKey,
            pending: successor,
          );
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
      hasDurabilityFailure: _hasDurabilityFailureForAccount(accountId),
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
    if (!_isDisposed && state.isFlushing) {
      _refreshActiveQueueView(isFlushing: false);
    }
  }

  AccountStrategyOutboxSummary _accountSummary(String? accountId) {
    if (accountId == null) return const AccountStrategyOutboxSummary();
    final recordsByStorageKey = <String, DurableOutboxRecord>{};
    for (final record in _recordsByStorageKey.values) {
      if (record.accountId != accountId) continue;
      recordsByStorageKey[record.storageKey] = record;
    }
    for (final record in _uncertainDurableIntents.values) {
      if (record.accountId != accountId) continue;
      recordsByStorageKey[record.storageKey] = record;
    }

    final storageKeysByStrategy = <String, Set<String>>{};
    for (final entry in recordsByStorageKey.entries) {
      (storageKeysByStrategy[entry.value.strategyPublicId] ??= <String>{})
          .add(entry.key);
    }
    for (final storageKey in <String>{
      ..._uncertainDurableRecords,
      ..._uncertainOversizedParking,
    }) {
      final strategyPublicId = _strategyIdForStorageKey(
        storageKey,
        accountId: accountId,
      );
      if (strategyPublicId != null) {
        (storageKeysByStrategy[strategyPublicId] ??= <String>{})
            .add(storageKey);
      }
    }

    final summaries = <String, StrategyOutboxSummary>{};
    final deletedStrategies = <String, int>{};
    for (final entry in storageKeysByStrategy.entries) {
      final isDeleted = entry.value.any(
        (storageKey) =>
            recordsByStorageKey[storageKey]?.lastError ==
            cloudStrategyDeletedMessage,
      );
      if (isDeleted) {
        deletedStrategies[entry.key] = entry.value.length;
        continue;
      }
      var queuedCount = 0;
      var inFlightCount = 0;
      var pausedCount = 0;
      var attentionCount = 0;
      var successorCount = 0;
      String? reason;
      for (final storageKey in entry.value) {
        final record = recordsByStorageKey[storageKey];
        final uncertain = _uncertainDurableRecords.contains(storageKey) ||
            _uncertainOversizedParking.contains(storageKey);
        if (record == null) {
          attentionCount += 1;
          reason ??= 'Cloud work could not be verified in the durable outbox.';
          continue;
        }
        final oversized = cloudOperationExceedsPolicy(record.pending.op);
        if (uncertain || oversized) {
          attentionCount += 1;
          reason ??= uncertain
              ? 'Cloud work could not be verified in the durable outbox.'
              : cloudOperationTooLargeMessage;
        } else {
          switch (record.status) {
            case DurableOutboxStatus.queued:
              queuedCount += 1;
            case DurableOutboxStatus.inFlight:
              inFlightCount += 1;
            case DurableOutboxStatus.paused:
              pausedCount += 1;
            case DurableOutboxStatus.attention:
              attentionCount += 1;
          }
          reason ??= record.lastError;
        }
        if (record.successorPending != null) successorCount += 1;
      }
      summaries[entry.key] = StrategyOutboxSummary(
        strategyPublicId: entry.key,
        queuedCount: queuedCount,
        inFlightCount: inFlightCount,
        pausedCount: pausedCount,
        attentionCount: attentionCount,
        successorCount: successorCount,
        reason: reason,
      );
    }
    return AccountStrategyOutboxSummary(
      accountId: accountId,
      strategies: summaries,
      deletedStrategies: deletedStrategies,
    );
  }

  String? _strategyIdForStorageKey(
    String storageKey, {
    required String accountId,
  }) {
    final parts = storageKey.split('|');
    if (parts.length < 3 || Uri.decodeComponent(parts.first) != accountId) {
      return null;
    }
    return Uri.decodeComponent(parts[1]);
  }

  void _publishAccountSummary() {
    if (_isDisposed) return;
    final summary = _accountSummary(state.accountId);
    final hasDurabilityFailure = _hasDurabilityFailureForCurrentAccount;
    if (_sameAccountSummary(state.accountOutbox, summary) &&
        state.hasDurabilityFailure == hasDurabilityFailure) {
      return;
    }
    state = state.copyWith(
      accountOutbox: summary,
      hasDurabilityFailure: hasDurabilityFailure,
    );
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

  bool _hasUncertainParkingFor({
    required String? accountId,
    required String? strategyPublicId,
  }) {
    if (accountId == null || strategyPublicId == null) return false;
    final prefix = '${Uri.encodeComponent(accountId)}|'
        '${Uri.encodeComponent(strategyPublicId)}|';
    return _uncertainOversizedParking.any((key) => key.startsWith(prefix));
  }

  bool get _hasUncertainParkingForActiveStrategy => _hasUncertainParkingFor(
        accountId: state.accountId,
        strategyPublicId: state.strategyPublicId,
      );

  bool _hasUncertainDurableRecordFor({
    required String? accountId,
    required String? strategyPublicId,
  }) {
    if (accountId == null || strategyPublicId == null) return false;
    final prefix = '${Uri.encodeComponent(accountId)}|'
        '${Uri.encodeComponent(strategyPublicId)}|';
    return _uncertainDurableRecords.any((key) => key.startsWith(prefix));
  }

  bool get _hasUncertainDurableRecordForActiveStrategy =>
      _hasUncertainDurableRecordFor(
        accountId: state.accountId,
        strategyPublicId: state.strategyPublicId,
      );

  bool _hasDurabilityFailureForAccount(String? accountId) {
    if (accountId == null) return false;
    final prefix = '${Uri.encodeComponent(accountId)}|';
    return _uncertainOversizedParking.any((key) => key.startsWith(prefix)) ||
        _uncertainDurableRecords.any((key) => key.startsWith(prefix));
  }

  bool get _hasDurabilityFailureForCurrentAccount =>
      _hasDurabilityFailureForAccount(state.accountId);

  /// How many times writing the outbox has failed, so a caller can tell
  /// whether its own save failed rather than an earlier one.
  int get persistenceFailureCount => _persistenceFailureCount;
  int _persistenceFailureCount = 0;

  void _recordPersistenceFailure(Object error, StackTrace stackTrace) {
    _persistenceFailureCount++;
    log('Durable outbox persistence failed: $error',
        name: 'strategy_outbox', error: error, stackTrace: stackTrace);
    if (_isDisposed) return;
    final queued = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.queuedByEntityKey,
    );
    final inFlight = Map<EntitySyncKey, InFlightEntityIntent>.from(
      state.inFlightByEntityKey,
    );
    final paused = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.pausedByEntityKey,
    );
    final attention = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.attentionByEntityKey,
    );
    for (final record in _uncertainDurableIntents.values.where((record) =>
        record.accountId == state.accountId &&
        record.strategyPublicId == state.strategyPublicId)) {
      attention[record.entityKey] = QueuedEntityIntent(
        entityKey: record.entityKey,
        pending: record.pending,
      );
      queued.remove(record.entityKey);
      inFlight.remove(record.entityKey);
      paused.remove(record.entityKey);
    }
    state = state.copyWith(
      queuedByEntityKey: queued,
      inFlightByEntityKey: inFlight,
      pausedByEntityKey: paused,
      attentionByEntityKey: attention,
      isFlushing: false,
      lastError: 'Cloud work could not be saved to the durable outbox: $error',
      hasDurabilityFailure: true,
    );
  }

  void _scheduleFlush({required bool flushImmediately}) {
    if (_isDisposed) return;
    if (flushImmediately) {
      unawaited(flushNow());
      return;
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDelay, () => unawaited(flushNow()));
  }

  void retryCurrentAccount() {
    if (_isDisposed) return;
    _scheduleBackgroundDrain(ignoreBackoff: true);
    if (state.queuedByEntityKey.isNotEmpty) {
      unawaited(flushNow());
    }
  }

  void _scheduleBackgroundDrain({bool ignoreBackoff = false}) {
    if (_isDisposed) return;
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
                record.status == DurableOutboxStatus.inFlight) &&
            !_uncertainDurableRecords.contains(record.storageKey) &&
            !cloudOperationExceedsPolicy(record.pending.op))
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
    if (_isDisposed) return;
    if (_networkBusy) {
      _backgroundRetryTimer = Timer(
        _busyBackgroundRetryDelay,
        () => unawaited(_drainNextBackgroundStrategy(
          ignoreBackoff: ignoreBackoff,
        )),
      );
      return;
    }
    await _writeTail;
    if (_isDisposed) return;
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
            !_uncertainDurableRecords.contains(record.storageKey) &&
            !cloudOperationExceedsPolicy(record.pending.op) &&
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
    if (lastAttemptAt == null ||
        record.status == DurableOutboxStatus.inFlight) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
    final exponent = record.pending.attempts.clamp(0, 6);
    return lastAttemptAt.add(
      Duration(milliseconds: 300 * (1 << exponent)),
    );
  }

  void _scheduleRetry(List<PendingOp> pending, {Duration? delay}) {
    if (_isDisposed || pending.isEmpty) return;
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
        // Live sync names every field changed since the version both were
        // drawn from, so the newer merge covers the older one's too.
        return ElementPatchOp(
          opId: replacementOpId,
          elementPublicId: desired.elementPublicId,
          pagePublicId: desired.pagePublicId ?? existing.pagePublicId,
          payload: desired.payload ?? existing.payload,
          sortIndex: desired.sortIndex ?? existing.sortIndex,
          expectedElementRevision: desired.expectedElementRevision,
          merge: desired.merge,
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
          merge: desired.merge,
        );
      }
    }
    return desired.withOpId(replacementOpId);
  }

  /// [resent] carries [original]'s work under a new op ID: the canvas's
  /// work stays the canvas's.
  void _keepCanvasWritten(
    StrategyOp original,
    StrategyOp resent, {
    bool keepLive = false,
  }) {
    if (_canvasOpIds.contains(original.opId)) _canvasOpIds.add(resent.opId);
    // Only a successor promoted behind its predecessor is the same live
    // work; a retry, made or chosen later, is sent checked.
    if (keepLive && _liveOpIds.contains(original.opId)) {
      _liveOpIds.add(resent.opId);
    }
  }

  /// Forgets the IDs of canvas work that landed or was dropped. Runs only
  /// inside a serialized write, so no op another write marked is still
  /// waiting for its record to be stored.
  void _pruneCanvasOpIds() {
    final pendingOpIds = {
      for (final record in [
        ..._recordsByStorageKey.values,
        ..._uncertainDurableIntents.values,
      ]) ...[
        record.pending.op.opId,
        if (record.successorPending case final successor?) successor.op.opId,
      ],
    };
    _canvasOpIds.retainAll(pendingOpIds);
    _liveOpIds.retainAll(pendingOpIds);
  }

  /// [op], refused for [refusal], as Keep mine sends it. After a field
  /// collision the user's fields win over what the server held when it
  /// refused ([serverHas]): the merge's base becomes that, so a teammate's
  /// change made after it still asks. (Its place is no longer named: a
  /// refusal does not say where the server has the row.) After a merge that
  /// left a group that can't stand, the user's whole group replaces the
  /// server's, revision-checked as any whole write is.
  static StrategyOp _keptMine(
    StrategyOp op, {
    required String? refusal,
    required CloudPayload? serverHas,
  }) {
    final merge = op.merge;
    if (merge == null) return op;
    if (refusal == OpRejectionReason.fieldConflict.wireName) {
      if (serverHas == null || merge.base == null) {
        return op.withMerge(merge.withoutBase());
      }
      final lineup = op is LineupPatchOp;
      final fields = [
        for (final field in merge.fields)
          if (field != placeMergeField) field,
      ];
      return op.withMerge(FieldMerge(
        fields: fields,
        base: mergeBaseValues(serverHas, fields, lineup: lineup),
      ));
    }
    if (refusal == OpRejectionReason.mergeInvalid.wireName) {
      return op.withMerge(null);
    }
    return op;
  }

  /// [successor] (rebased onto the revision [predecessor] landed at) once
  /// [predecessor] landed. After a merge, that revision may also hold a
  /// teammate's fields this client never drew, so a whole write or a delete
  /// keeps claiming the revision it was [original]ly made from. A merge
  /// already names its change from the predecessor (see [_asSuccessorOf]).
  static StrategyOp _onLandedPredecessor(
    StrategyOp successor, {
    required StrategyOp original,
    required StrategyOp predecessor,
  }) =>
      successor.merge == null && predecessor.merge != null
          ? original
          : successor;

  /// [op], made to wait behind [predecessor], which is sent first. When the
  /// predecessor is this canvas's own work ([drawn]) and merges by field,
  /// [op]'s merge also names every field the predecessor does, with the
  /// user's current values: a field the user set back meanwhile is written
  /// again, and should the predecessor be refused and the user keep theirs,
  /// this one change still carries all of it. Its base, for those fields, is
  /// what the predecessor writes, which the server holds once it lands.
  /// Work the canvas never drew (recovered after a restart) is left out:
  /// the user's edits were made against what the canvas showed. Worked out
  /// as the successor is made, while [drawn] is known, and saved with it.
  static StrategyOp _asSuccessorOf(
    StrategyOp op,
    StrategyOp predecessor, {
    required bool drawn,
  }) {
    final merge = op.merge;
    final written = predecessor.merge;
    final writtenPayload = predecessor.payload;
    if (merge == null || written == null || writtenPayload == null || !drawn) {
      return op;
    }
    final lineup = op is LineupPatchOp;
    final fields = {...written.fields, ...merge.fields}.toList()..sort();
    final base = merge.base;
    if (base == null) return op.withMerge(FieldMerge(fields: fields));
    final rebased = <String, Object?>{};
    for (final field in fields) {
      if (!written.fields.contains(field)) {
        if (base.containsKey(field)) rebased[field] = base[field];
      } else if (field == placeMergeField) {
        if (predecessor.sortIndex case final at?) rebased[field] = at;
      } else {
        final value = mergeFieldValue(writtenPayload, field, lineup: lineup);
        if (value.present) rebased[field] = value.value;
      }
    }
    return op.withMerge(FieldMerge(fields: fields, base: rebased));
  }

  /// [op] as an add bringing its element or lineup back over the tombstone
  /// at [revision], with the payload and place the user has. Null for a
  /// change that does not hold them (a reorder, a delete); live sync's
  /// patches always do.
  static StrategyOp? _restoreOp(StrategyOp op, int revision) {
    final opId = const Uuid().v4();
    return switch (op) {
      ElementAddOp(
        :final elementPublicId,
        :final pagePublicId,
        :final payload,
        :final sortIndex,
      ) ||
      ElementPatchOp(
        :final elementPublicId,
        pagePublicId: final pagePublicId?,
        payload: final payload?,
        sortIndex: final sortIndex?,
      ) =>
        ElementAddOp(
          opId: opId,
          elementPublicId: elementPublicId,
          pagePublicId: pagePublicId,
          payload: payload,
          sortIndex: sortIndex,
          expectedElementRevision: revision,
        ),
      LineupAddOp(
        :final lineupPublicId,
        :final pagePublicId,
        :final payload,
        :final sortIndex,
      ) ||
      LineupPatchOp(
        :final lineupPublicId,
        pagePublicId: final pagePublicId?,
        payload: final payload?,
        sortIndex: final sortIndex?,
      ) =>
        LineupAddOp(
          opId: opId,
          lineupPublicId: lineupPublicId,
          pagePublicId: pagePublicId,
          payload: payload,
          sortIndex: sortIndex,
          expectedLineupRevision: revision,
        ),
      _ => null,
    };
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
        :final merge,
      ) =>
        ElementPatchOp(
          opId: opId,
          elementPublicId: elementPublicId,
          pagePublicId: pagePublicId,
          payload: payload,
          sortIndex: sortIndex,
          expectedElementRevision: revision,
          merge: merge,
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
        :final merge,
      ) =>
        LineupPatchOp(
          opId: opId,
          lineupPublicId: lineupPublicId,
          pagePublicId: pagePublicId,
          payload: payload,
          sortIndex: sortIndex,
          expectedLineupRevision: revision,
          merge: merge,
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

  /// The queue's error for [attention] and [paused] work in a strategy:
  /// the active one unless [accountId] and [strategyPublicId] name the one
  /// being opened, whose state is not built yet.
  String? _loadedAttentionMessage({
    required List<DurableOutboxLoadIssue> loadIssues,
    required Map<EntitySyncKey, QueuedEntityIntent> paused,
    required Map<EntitySyncKey, QueuedEntityIntent> attention,
    String? accountId,
    String? strategyPublicId,
  }) {
    accountId ??= state.accountId;
    strategyPublicId ??= state.strategyPublicId;
    DurableOutboxRecord? recordFor(EntitySyncKey key) =>
        accountId == null || strategyPublicId == null
            ? null
            : _recordsByStorageKey[DurableOutboxRecord.createStorageKey(
                accountId: accountId,
                strategyPublicId: strategyPublicId,
                entityKey: key,
              )];
    if (loadIssues.isNotEmpty) {
      return 'The cloud outbox contains unreadable saved work.';
    }
    if (_hasUncertainParkingForActiveStrategy) {
      return _uncertainOversizedParkingMessage ??
          'Cloud work could not be verified in the durable outbox. '
              'Nothing was sent.';
    }
    if (_hasUncertainDurableRecordForActiveStrategy) {
      return 'Cloud work could not be verified in the durable outbox.';
    }
    if (attention.isNotEmpty) {
      final hasOversizedWork = attention.entries.any((entry) {
        if (cloudOperationExceedsPolicy(entry.value.pending.op)) return true;
        final record = recordFor(entry.key);
        return record?.pending.op.opId == entry.value.pending.op.opId &&
            record?.lastError == cloudOperationTooLargeMessage;
      });
      if (hasOversizedWork) return cloudOperationTooLargeMessage;
      // A change the server refused for its own reason (a lineup, a page
      // in the trash) keeps that reason, so the sync button does not call
      // it a conflict. Other attention beside it is noted so it is not left
      // unexplained.
      String? specificReason;
      var hasOtherWork = false;
      for (final entry in attention.entries) {
        final record = recordFor(entry.key);
        final lastError = record?.pending.op.opId == entry.value.pending.op.opId
            ? record?.lastError
            : null;
        final reason = lastError == OpRejectionReason.deleted.wireName
            ? teammateDeletedMessage
            : lastError;
        if (reason == lineupPageMismatchMessage ||
            reason == lineupOverlapMessage ||
            reason == teammateDeletedMessage ||
            reason == retiredLineupOpMessage ||
            reason == pageDeletedMessage) {
          // A second, different reason is other work too: one explanation
          // must not stand for both.
          if (specificReason != null && reason != specificReason) {
            hasOtherWork = true;
          }
          specificReason ??= reason;
        } else {
          hasOtherWork = true;
        }
      }
      if (specificReason != null) {
        return hasOtherWork
            ? '$specificReason. $otherWorkNeedsAttentionNote'
            : specificReason;
      }
      return 'Some saved work needs attention.';
    }
    if (paused.isNotEmpty) return 'Some saved work is paused after retries.';
    return null;
  }
}
