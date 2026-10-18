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
import 'package:icarus/collab/page_changes.dart';
import 'package:icarus/collab/strategy_capabilities.dart';
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

  /// How many outbox records hold changes that have not landed: one per
  /// item, however many edits to it are waiting.
  int get unsentRecordCount =>
      queuedCount + inFlightCount + pausedCount + attentionCount;
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

/// The strategy-level change (map, theme) to [strategyPublicId] still
/// waiting in [queue]'s outbox, sent or not, paused or refused: the newest
/// one, the change queued behind one being sent included. Null when none
/// waits.
StrategyPatchOp? waitingStrategyPatch(
  StrategyOpQueueState queue,
  String strategyPublicId,
) {
  if (queue.strategyPublicId != strategyPublicId) return null;
  const key = EntitySyncKey.strategy();
  final op = (queue.successorByEntityKey[key] ??
          queue.queuedByEntityKey[key] ??
          queue.pausedByEntityKey[key] ??
          queue.attentionByEntityKey[key])
      ?.pending
      .op;
  final waiting = op ?? queue.inFlightByEntityKey[key]?.pending.op;
  return waiting is StrategyPatchOp ? waiting : null;
}

/// Whether a strategy-level change to [strategyPublicId] that [queue] can
/// no longer take back may still land: one being sent, or one waiting
/// behind another. A canvas set back to the server's map and theme then
/// needs that written too, or the change landing undoes it.
bool strategyPatchMayLand(
  StrategyOpQueueState queue,
  String strategyPublicId,
) {
  if (queue.strategyPublicId != strategyPublicId) return false;
  const key = EntitySyncKey.strategy();
  return queue.inFlightByEntityKey.containsKey(key) ||
      queue.successorByEntityKey.containsKey(key);
}

/// [header], the server's as read, as this device knows the server holds
/// it: when the read is older than this device's own strategy-level change
/// that landed since, that change's map and theme at the revision it
/// landed at. A read at or past that revision shows what the server holds
/// then, a teammate's later change included.
RemoteStrategyHeader knownStrategyHeader(
  Ref ref,
  RemoteStrategyHeader header,
) {
  final landed = ref
      .read(strategyOpQueueProvider.notifier)
      .landedStrategyPatch(header.publicId);
  return landed == null || header.revision >= landed.revision
      ? header
      : header.withPatch(landed.payload, revision: landed.revision);
}

/// [header] as this device draws the strategy: as it knows the server holds
/// it (see knownStrategyHeader), with the strategy-level change still
/// waiting in the outbox on top, so a map or theme changed offline shows
/// until it lands (see waitingStrategyPatch).
RemoteStrategyHeader drawnStrategyHeader(
  Ref ref,
  RemoteStrategyHeader header,
) {
  final known = knownStrategyHeader(ref, header);
  final waiting =
      waitingStrategyPatch(ref.read(strategyOpQueueProvider), header.publicId);
  return waiting == null ? known : known.withPatch(waiting.payload);
}

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
  Map<String, DurableOutboxRecord> _recordsByStorageKey = {};
  final Set<EntitySyncKey> _awaitingRemoteAdoption = {};

  /// By strategy, this device's newest strategy-level change that the server
  /// took: its payload, and the revision the server held it at.
  final Map<String, ({CloudPayload payload, int revision})>
      _landedStrategyPatches = {};

  /// This device's newest strategy-level change to [strategyPublicId] that
  /// the server took, and the revision it held it at (see
  /// knownStrategyHeader). Null if none landed since the app started.
  ({CloudPayload payload, int revision})? landedStrategyPatch(
    String strategyPublicId,
  ) =>
      _landedStrategyPatches[strategyPublicId];

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
    _recordsByStorageKey = _holdIncompletePageCopies({
      for (final record in loaded.records)
        record.storageKey: _retiredAsAttention(_resumedAfterUpgrade(record)),
    });
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
    _landedPageChanges.clear();
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

  /// Whether [opId] is work the canvas holds: queued from its edits, or
  /// drawn on it from the outbox ([noteDrawnWork]).
  bool isCanvasWork(String opId) => _canvasOpIds.contains(opId);

  /// The canvas now shows [opIds], work recovered from the outbox that it
  /// drew on load: their acks are the canvas's own from here on, as if it
  /// had queued them. Ops no longer in the outbox are left out.
  void noteDrawnWork(Iterable<String> opIds) {
    final pendingOpIds = {
      for (final pending in state.pending) pending.op.opId,
    };
    _canvasOpIds.addAll(opIds.where(pendingOpIds.contains));
  }

  Future<void> enqueue(
    StrategyOp op, {
    bool flushImmediately = false,
  }) {
    if (isPageChangeOp(op)) {
      return enqueuePageChange(op, flushImmediately: flushImmediately);
    }
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
      if (isPageChangeOp(op)) {
        await enqueuePageChange(op);
        continue;
      }
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

  /// Adds [op], a page change (see isPageChangeOp), to the end of the
  /// active strategy's ordered list of them. They are sent one at a time in
  /// that order (see [_selectBatch]), so no change to a page replaces
  /// another. Only a change the server has never been sent is folded into:
  /// a rename into the newest change to its page, if that is an add or a
  /// rename, and a move into the move of the same page made just before it.
  /// Anything else waits behind what is already there, a delete included:
  /// a change that was sent may have landed even when its answer never
  /// came, so nothing is taken back on the assumption it did not.
  Future<void> enqueuePageChange(
    StrategyOp op, {
    bool flushImmediately = false,
  }) {
    assert(isPageChangeOp(op));
    return _serializeWrite(
      () => _appendPageChangeLocked(op, flushImmediately: flushImmediately),
    );
  }

  Future<void> _appendPageChangeLocked(
    StrategyOp op, {
    required bool flushImmediately,
  }) async {
    final accountId = state.accountId;
    final strategyPublicId = state.strategyPublicId;
    final pageId = op.pagePublicId;
    if (accountId == null || strategyPublicId == null || pageId == null) {
      state = state.copyWith(
        lastError: 'Cloud work could not be queued without an active account.',
        hasDurabilityFailure: true,
      );
      return;
    }
    final list = _pageChangeRecords(accountId, strategyPublicId);
    bool forPage(DurableOutboxRecord record) =>
        record.pending.op.pagePublicId == pageId;
    // Never claimed for a send: a send that failed counts an attempt, and
    // one cut short leaves the record in flight.
    bool neverSent(DurableOutboxRecord record) =>
        record.status == DurableOutboxStatus.queued &&
        record.pending.attempts == 0 &&
        !_uncertainDurableRecords.contains(record.storageKey);
    try {
      final newest = list.where(forPage).lastOrNull;
      final last = list.lastOrNull;
      if (op is PageReorderOp &&
          last != null &&
          neverSent(last) &&
          last.pending.op is PageReorderOp &&
          forPage(last)) {
        // Moved again with nothing made since: the newer place stands.
        await _putRecord(last.copyWith(
          pending: PendingOp(
            op: PageReorderOp(
              opId: const Uuid().v4(),
              pagePublicId: pageId,
              sortIndex: op.sortIndex,
              expectedStrategyRevision: last.pending.op.expectedRevision!,
            ),
            clientId: last.pending.clientId,
          ),
          updatedAt: DateTime.now(),
        ));
      } else if (op is PagePatchOp &&
          newest != null &&
          neverSent(newest) &&
          (newest.pending.op is PageAddOp ||
              newest.pending.op is PagePatchOp)) {
        final waiting = newest.pending.op;
        final merged = waiting is PagePatchOp
            // Kept at the revision the waiting rename has: it may have
            // moved past this device's own changes since it was made.
            ? PagePatchOp(
                opId: const Uuid().v4(),
                pagePublicId: pageId,
                payload: {...waiting.payload, ...op.payload},
                expectedPageRevision: waiting.expectedPageRevision,
              )
            : _mergeQueuedIntent(waiting, op)!;
        await _putRecord(newest.copyWith(
          pending: PendingOp(op: merged, clientId: newest.pending.clientId),
          updatedAt: DateTime.now(),
        ));
      } else {
        final now = DateTime.now();
        final oversized = cloudOperationExceedsPolicy(op);
        await _putRecord(DurableOutboxRecord(
          accountId: accountId,
          strategyPublicId: strategyPublicId,
          entityKey: EntitySyncKey.pageChange(const Uuid().v4()),
          pending: PendingOp(op: op, clientId: state.clientId!),
          status: oversized
              ? DurableOutboxStatus.attention
              : DurableOutboxStatus.queued,
          createdAt: now,
          updatedAt: now,
          lastError: oversized ? cloudOperationTooLargeMessage : null,
          pageChangeSequence: list.fold<int>(
                0,
                (last, record) =>
                    math.max(last, record.pageChangeSequence ?? 0),
              ) +
              1,
        ));
      }
    } catch (error, stackTrace) {
      _recordPersistenceFailure(error, stackTrace);
      return;
    }
    _pruneCanvasOpIds();
    _refreshActiveQueueView();
    _scheduleFlush(flushImmediately: flushImmediately);
  }

  static bool _isPageChange(DurableOutboxRecord record) =>
      record.entityKey.kind == EntitySyncKeyKind.pageChange;

  /// [strategyPublicId]'s page changes, in the order they were made: each
  /// as last saved, or as last asked for when that save failed.
  List<DurableOutboxRecord> _pageChangeRecords(
    String accountId,
    String strategyPublicId,
  ) {
    final byStorageKey = <String, DurableOutboxRecord>{
      for (final record in [
        ..._recordsByStorageKey.values,
        ..._uncertainDurableIntents.values,
      ])
        if (record.accountId == accountId &&
            record.strategyPublicId == strategyPublicId &&
            _isPageChange(record))
          record.storageKey: record,
    };
    return byStorageKey.values.toList()..sort(_inListOrder);
  }

  /// Whether [record] holds page changes as builds before the list saved
  /// them (outbox versions 1 to 3): in its page's descriptor slot, as its
  /// change or the one waiting behind it. Such a record is read, merged
  /// and sent as those builds did until it drains, and the list's own
  /// changes wait for it (see [_selectBatch]). Nothing rewrites it into
  /// the list.
  static bool _isOldPageChange(DurableOutboxRecord record) =>
      record.entityKey.kind == EntitySyncKeyKind.pageDescriptor &&
      [record.pending.op, record.successorPending?.op]
          .any((op) => op != null && isPageChangeOp(op));

  /// [strategyPublicId]'s page changes saved by a build before the list
  /// (see [_isOldPageChange]), in the order those builds send them: the
  /// outbox's own order.
  List<DurableOutboxRecord> _oldPageChangeRecords(
    String accountId,
    String strategyPublicId,
  ) =>
      [
        for (final record in _recordsByStorageKey.values)
          if (record.accountId == accountId &&
              record.strategyPublicId == strategyPublicId &&
              _isOldPageChange(record))
            record,
      ];

  static int _inListOrder(DurableOutboxRecord left, DurableOutboxRecord right) {
    final place =
        (left.pageChangeSequence ?? 0).compareTo(right.pageChangeSequence ?? 0);
    return place != 0 ? place : left.createdAt.compareTo(right.createdAt);
  }

  /// The active strategy's page changes that landed in this session, each
  /// with the revision it landed at, oldest first: drawn until a read shows
  /// them (see [pageChangesToDraw]).
  final List<({StrategyOp op, int revision, bool applied})> _landedPageChanges =
      [];

  /// The strategy revision [snapshot]'s pages are drawn at: its read's, or
  /// the revision this device's own add, delete or reorder was applied at
  /// since, if later. That one was checked against the revision before it,
  /// which this device knew, so the pages drawn are exactly the server's at
  /// it. A change made from them is made against it. (One the server found
  /// nothing to do for says nothing about who made its revision.)
  int drawnStrategyRevision(RemoteEditorSnapshot snapshot) {
    var revision = snapshot.header.revision;
    if (snapshot.header.publicId != state.strategyPublicId) return revision;
    for (final landed in _landedPageChanges) {
      if (landed.applied && renumbersPages(landed.op)) {
        revision = math.max(revision, landed.revision);
      }
    }
    return revision;
  }

  /// The page changes to draw over [snapshot]'s list of pages, oldest first
  /// (see drawPages): the active strategy's that landed but [snapshot]'s
  /// read does not show yet, then every one still waiting, sent or not,
  /// paused or refused, as the canvas draws waiting work.
  List<StrategyOp> pageChangesToDraw(RemoteEditorSnapshot snapshot) {
    final accountId = state.accountId;
    final strategyPublicId = state.strategyPublicId;
    if (accountId == null ||
        strategyPublicId == null ||
        snapshot.header.publicId != strategyPublicId) {
      return const [];
    }
    final old = _oldPageChangeRecords(accountId, strategyPublicId);
    return [
      for (final landed in _landedPageChanges)
        if (!_readShows(snapshot, landed)) landed.op,
      for (final record in old)
        if (isPageChangeOp(record.pending.op)) record.pending.op,
      for (final record in old)
        if (record.successorPending?.op case final successor?
            when isPageChangeOp(successor))
          successor,
      for (final record in _pageChangeRecords(accountId, strategyPublicId))
        record.pending.op,
    ];
  }

  /// Whether [snapshot]'s read already shows [landed].
  static bool _readShows(
    RemoteEditorSnapshot snapshot,
    ({StrategyOp op, int revision, bool applied}) landed,
  ) {
    if (renumbersPages(landed.op)) {
      return snapshot.header.revision >= landed.revision;
    }
    final page = snapshot.pages
        .where((page) => page.publicId == landed.op.pagePublicId)
        .firstOrNull;
    return page == null || page.revision >= landed.revision;
  }

  /// The revision of each page this device's own rename (or side change
  /// from the list) moved it to since [snapshot]'s read, as #331's
  /// knownStrategyHeader does for the strategy: a rename made from the page
  /// as drawn is made against it, and not refused for this device's own
  /// change.
  Map<String, int> landedPageRevisions(RemoteEditorSnapshot snapshot) {
    if (snapshot.header.publicId != state.strategyPublicId) return const {};
    final revisions = <String, int>{};
    for (final landed in _landedPageChanges) {
      final pageId = landed.op.pagePublicId;
      if (!landed.applied ||
          landed.op is! PagePatchOp ||
          pageId == null ||
          _readShows(snapshot, landed)) {
        continue;
      }
      revisions[pageId] = math.max(revisions[pageId] ?? 0, landed.revision);
    }
    return revisions;
  }

  /// Whether the active strategy's page [pageId] was deleted on this device
  /// and the delete has not landed yet.
  bool isDeletedHere(String pageId) {
    final accountId = state.accountId;
    final strategyPublicId = state.strategyPublicId;
    if (accountId == null || strategyPublicId == null) return false;
    return [
      for (final record in [
        ..._oldPageChangeRecords(accountId, strategyPublicId),
        ..._pageChangeRecords(accountId, strategyPublicId),
      ]) ...[
        record.pending.op,
        if (record.successorPending case final successor?) successor.op,
      ],
    ].any((op) => op is PageDeleteOp && op.pagePublicId == pageId);
  }

  /// Queues the copy of a page this computer made for "+" (see
  /// page_made_here.dart) for [strategyPublicId], which must be the active
  /// strategy: [add], which copies nothing on the server, at the end of the
  /// page changes, then [content], what the copy holds, as work for its page
  /// made off the canvas (see [enqueueOffCanvas]). The add and its content
  /// are stored in one write, so the copy is kept whole or not at all, and
  /// the content is sent once the add lands (see [_selectBatch]). False,
  /// with nothing queued, when that write fails (the queue reports the
  /// failure) or another strategy is active.
  Future<bool> enqueuePageCopy(
    PageAddOp add,
    List<StrategyOp> content, {
    required String strategyPublicId,
  }) {
    assert(add.copyContentFromPagePublicId == null);
    final accountId = state.accountId;
    final clientId = state.clientId;
    if (accountId == null ||
        clientId == null ||
        state.strategyPublicId != strategyPublicId) {
      return Future.value(false);
    }
    return _serializeWrite(() async {
      final list = _pageChangeRecords(accountId, strategyPublicId);
      final now = DateTime.now();
      final oversized = cloudOperationExceedsPolicy(add);
      final addRecord = DurableOutboxRecord(
        accountId: accountId,
        strategyPublicId: strategyPublicId,
        entityKey: EntitySyncKey.pageChange(const Uuid().v4()),
        pending: PendingOp(op: add, clientId: clientId),
        status: oversized
            ? DurableOutboxStatus.attention
            : DurableOutboxStatus.queued,
        createdAt: now,
        updatedAt: now,
        lastError: oversized ? cloudOperationTooLargeMessage : null,
        pageChangeSequence: list.fold<int>(
              0,
              (last, record) => math.max(last, record.pageChangeSequence ?? 0),
            ) +
            1,
      );
      return _putPageCopyLocked(addRecord, content, clientId: clientId);
    });
  }

  /// Turns the add of [pageId] in [strategyPublicId] that "+" queued for
  /// the server to copy the page into one that copies nothing, with
  /// [content], the copy this computer made, queued behind it, all in one
  /// write (see [enqueuePageCopy]). The add keeps its place among the page
  /// changes. Only an add never sent is changed, as enqueuePageChange
  /// judges it: one sent may have landed, copy and all. False, changing
  /// nothing, for any other, or when the write fails.
  Future<bool> copyWaitingPageAddHere(
    String pageId,
    List<StrategyOp> content, {
    required String strategyPublicId,
  }) {
    final accountId = state.accountId;
    if (accountId == null || state.strategyPublicId != strategyPublicId) {
      return Future.value(false);
    }
    return _serializeWrite(() async {
      final waiting = _pageChangeRecords(accountId, strategyPublicId)
          .where((record) =>
              record.pending.op is PageAddOp &&
              record.pending.op.pagePublicId == pageId)
          .firstOrNull;
      final add = waiting?.pending.op;
      if (waiting == null ||
          add is! PageAddOp ||
          add.copyContentFromPagePublicId == null ||
          waiting.status != DurableOutboxStatus.queued ||
          waiting.pending.attempts > 0 ||
          _uncertainDurableRecords.contains(waiting.storageKey) ||
          !identical(_recordsByStorageKey[waiting.storageKey], waiting)) {
        return false;
      }
      final addRecord = waiting.copyWith(
        pending: PendingOp(
          op: PageAddOp(
            opId: const Uuid().v4(),
            pagePublicId: add.pagePublicId,
            payload: add.payload,
            sortIndex: add.sortIndex,
            expectedStrategyRevision: add.expectedStrategyRevision,
          ),
          clientId: waiting.pending.clientId,
        ),
        updatedAt: DateTime.now(),
      );
      return _putPageCopyLocked(
        addRecord,
        content,
        clientId: waiting.pending.clientId,
      );
    });
  }

  /// Stores [addRecord], naming the copy's items and lineup groups (see
  /// DurableOutboxRecord.pageCopyKeys), and a new record for each op of
  /// [content], work for the new page that waits for its add (see
  /// DurableOutboxRecord.waitsForPageAdd), in one write, then holds them.
  /// False, holding none of them, when the write fails.
  Future<bool> _putPageCopyLocked(
    DurableOutboxRecord addRecord,
    List<StrategyOp> content, {
    required String clientId,
  }) async {
    final records = [
      addRecord.copyWith(pageCopyKeys: [
        for (final op in content) '${EntitySyncKey.forStrategyOp(op)!}',
      ]),
      for (final op in content)
        DurableOutboxRecord(
          accountId: addRecord.accountId,
          strategyPublicId: addRecord.strategyPublicId,
          entityKey: EntitySyncKey.forStrategyOp(op)!,
          pending: PendingOp(op: op, clientId: clientId),
          status: cloudOperationExceedsPolicy(op)
              ? DurableOutboxStatus.attention
              : DurableOutboxStatus.queued,
          createdAt: addRecord.createdAt,
          updatedAt: addRecord.updatedAt,
          lastError: cloudOperationExceedsPolicy(op)
              ? cloudOperationTooLargeMessage
              : null,
          waitsForPageAdd: true,
        ),
    ];
    try {
      await _store.putAll(records);
    } catch (error, stackTrace) {
      _recordPersistenceFailure(error, stackTrace);
      return false;
    }
    for (final record in records) {
      _recordsByStorageKey[record.storageKey] = record;
    }
    _publishAccountSummary();
    _refreshActiveQueueView();
    _scheduleFlush(flushImmediately: true);
    return true;
  }

  /// Queues [op], work for a page the canvas did not draw it on (an item
  /// copied to another page). Its ack is marked restored: if that page is
  /// on screen by then, it shows the item from the server's copy, like a
  /// teammate's, instead of taking it as something the canvas removed.
  /// Returns whether the queue holds [op]: nothing on screen keeps it, so
  /// when the outbox could not store it, the caller must say so.
  Future<bool> enqueueOffCanvas(
    StrategyOp op, {
    bool flushImmediately = false,
  }) async {
    final key = EntitySyncKey.forStrategyOp(op)!;
    final canvasSession = _canvasSession;
    final madeLive = liveStamp;
    await _serializeWrite(() => _syncDesiredLocked(
          keys: <EntitySyncKey>{key},
          desiredOps: <EntitySyncKey, StrategyOp?>{key: op},
          flushImmediately: flushImmediately,
          canvasSession: canvasSession,
          madeLive: madeLive,
          onCanvas: false,
        ));
    return state.pending.any(
          (pending) => EntitySyncKey.forStrategyOp(pending.op) == key,
        ) ||
        state.lastAckBatch.any((acked) => acked.entityKey == key);
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
  /// it is. Ops made with [onCanvas] false are never the canvas's work.
  /// [madeLive] is the live stamp the work was made with (see [_markLive]).
  Future<void> _syncDesiredLocked({
    required Set<EntitySyncKey> keys,
    required Map<EntitySyncKey, StrategyOp?> desiredOps,
    required bool flushImmediately,
    required int canvasSession,
    required int? madeLive,
    Set<String> heldOpIds = const {},
    bool onCanvas = true,
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
      if (onCanvas &&
          canvasSession == _canvasSession &&
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
        // Page changes wait in their list, which reconciling a page's
        // content never touches.
        if (key.kind == EntitySyncKeyKind.pageChange) continue;
        final desired = desiredOps[key];
        final existing = queued[key];
        final inFlightIntent = state.inFlightByEntityKey[key];
        final inFlight = inFlightIntent?.pending.op;
        final successorIntent = successors[key];
        final pausedIntent = paused[key];
        final attentionIntent = attention[key];
        if (desired != null && heldOpIds.contains(desired.opId)) {
          // Kept work that has landed or been replaced since is not written
          // again.
          if (![
            existing?.pending,
            inFlightIntent?.pending,
            successorIntent?.pending,
            pausedIntent?.pending,
            attentionIntent?.pending,
          ].any((pending) => pending?.op.opId == desired.opId)) {
            continue;
          }
          // Kept paused or refused work stays as it is, unless its record
          // could not be saved and is written again here.
          if ((pausedIntent != null || attentionIntent != null) &&
              !_uncertainDurableRecords.contains(
                DurableOutboxRecord.createStorageKey(
                  accountId: accountId,
                  strategyPublicId: strategyPublicId,
                  entityKey: key,
                ),
              )) {
            continue;
          }
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

  /// Holds the waiting work of each of [waiting]'s entities in attention,
  /// with [undrawableWorkMessage]: merged onto the server's version as it
  /// is now (at revision serverRevision), it can't be read. It is neither
  /// sent nor dropped until the user chooses: Keep mine saves the user's
  /// version whole over the server's at that revision, Use cloud drops it.
  /// Only work still waiting as the op the page tried to draw (opId) and
  /// not being sent is held; refused work keeps its own reason.
  Future<void> holdWorkThatNoLongerFits(
    Map<EntitySyncKey, ({String opId, int? serverRevision})> waiting,
  ) {
    return _serializeWrite(() async {
      var changed = false;
      try {
        for (final MapEntry(:key, value: (:opId, :serverRevision))
            in waiting.entries) {
          final record = _recordForActiveKey(key);
          if (record == null ||
              record.pending.op.opId != opId ||
              record.lastError == undrawableWorkMessage ||
              // Refused for a reason of its own (a deleted page, lost edit
              // access, an older format): that reason stands.
              (record.status == DurableOutboxStatus.attention &&
                  !_refusedAsConflict(record.lastError)) ||
              // Being sent now: the server's answer decides.
              (record.status == DurableOutboxStatus.inFlight &&
                  _drainingStrategy ==
                      (
                        accountId: record.accountId,
                        strategyPublicId: record.strategyPublicId,
                      ))) {
            continue;
          }
          await _putRecord(record.copyWith(
            status: DurableOutboxStatus.attention,
            updatedAt: DateTime.now(),
            lastError: undrawableWorkMessage,
            latestServerRevision: serverRevision ?? record.latestServerRevision,
          ));
          changed = true;
        }
      } catch (error, stackTrace) {
        _recordPersistenceFailure(error, stackTrace);
        return;
      }
      if (changed) _refreshActiveQueueView(clearError: true);
    });
  }

  /// Whether [refusal] says the server refused the work because it collided
  /// with the row as it is now: what Keep mine resolves by sending the
  /// user's version over it.
  static bool _refusedAsConflict(String? refusal) => {
        OpRejectionReason.fieldConflict.wireName,
        OpRejectionReason.mergeInvalid.wireName,
        OpRejectionReason.revisionMismatch.wireName,
        OpRejectionReason.missingExpectedRevision.wireName,
      }.contains(refusal);

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
            livePageIds
                .contains(key.pageId ?? record?.pending.op.pagePublicId) &&
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
      // Work the dropped change held back (a page change behind a refused
      // one, an edit behind a refused delete) can go now.
      if (discarded.isNotEmpty) _scheduleFlush(flushImmediately: true);
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
      // FORBIDDEN refuses the whole batch. Sending it again can only work
      // once edit access is back, so it waits for the user's Retry.
      final editAccessGone = !strategyDeleted &&
          isTypedConvexForbiddenError(error) &&
          await _editAccessIsConfirmedGone(
            strategyPublicId,
            accountId: accountId,
          );
      if (strategyDeleted) {
        await _resolveDeletedStrategy(
          accountId: accountId,
          strategyPublicId: strategyPublicId,
        );
      } else if (editAccessGone) {
        AppErrorReporter.reportWarning(
          'Cloud sync paused ${batch.length} change(s) for strategy '
          '$strategyPublicId: this account can no longer edit it',
          source: 'cloud_sync.op_queue',
        );
        await _restoreRecordsAfterFailure(
          batch,
          lastError: editAccessRemovedMessage,
          countsAsFailure: false,
          pause: true,
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
      final held = _holdIncompletePageCopies(_recordsByStorageKey);
      if (!identical(held, _recordsByStorageKey)) {
        _recordsByStorageKey = held;
        _refreshActiveQueueView();
      }
      final now = DateTime.now();
      final selected = _selectBatch(
        accountId: accountId,
        strategyPublicId: strategyPublicId,
        ignoreBackoff: ignoreBackoff,
        now: now,
      );
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

  /// Whether [record] could go out now: waiting or interrupted mid-send,
  /// saved, within the size the server takes, and past its backoff unless
  /// [ignoreBackoff].
  bool _sendableNow(
    DurableOutboxRecord record, {
    required bool ignoreBackoff,
    required DateTime now,
  }) =>
      (record.status == DurableOutboxStatus.queued ||
          record.status == DurableOutboxStatus.inFlight) &&
      !_uncertainDurableRecords.contains(record.storageKey) &&
      !cloudOperationExceedsPolicy(record.pending.op) &&
      (ignoreBackoff || !_nextAttemptAt(record).isAfter(now));

  /// The next batch to send for [strategyPublicId], in the order the server
  /// is to apply it.
  ///
  /// It holds at most one page change, and that goes last, after the
  /// batch's other work: work queued before it is in this batch or an
  /// earlier one, so an add copies its source page with the edit made just
  /// before "+". A refused page change is answered before the next is sent,
  /// each checked against the revision it was made on. Renames go before
  /// adds, deletes and reorders: those renumber pages, which moves the
  /// revision of every page that moves on, so a rename made before one
  /// landed would be refused for a change this device made. The result is
  /// the same either way, since a rename does not depend on where the page
  /// is. Adds, deletes and reorders go strictly in the order they were
  /// made, each placed against the ones before it: one refused, paused or
  /// still backing off holds those after it. Everything else on a page
  /// whose add has not landed waits for it. A delete waits for the rest of
  /// its page's work, so the page's last edits are in the trash with it; a
  /// rename or side change made after it waits behind it (see
  /// [_isBehindDelete]).
  ///
  /// Page changes saved by a build before the list are sent as that build
  /// sends them, with the rest of the outbox (see [_oldPageChangeRecords]).
  /// The list waits until none is left, landed or settled by the user.
  List<DurableOutboxRecord> _selectBatch({
    required String accountId,
    required String strategyPublicId,
    required bool ignoreBackoff,
    required DateTime now,
  }) {
    bool sendable(DurableOutboxRecord record) =>
        _sendableNow(record, ignoreBackoff: ignoreBackoff, now: now);
    bool waiting(DurableOutboxRecord record) =>
        (record.status == DurableOutboxStatus.queued ||
            record.status == DurableOutboxStatus.inFlight) &&
        !cloudOperationExceedsPolicy(record.pending.op);
    final records = _recordsByStorageKey.values
        .where((record) =>
            record.accountId == accountId &&
            record.strategyPublicId == strategyPublicId)
        .toList(growable: false);
    final list = records.where(_isPageChange).toList()..sort(_inListOrder);
    final behindDelete = _isBehindDelete(list);
    final unlandedAdds = {
      for (final record in list)
        if (record.pending.op is PageAddOp) record.pending.op.pagePublicId,
    };
    final renames = list
        .where((record) =>
            record.pending.op is PagePatchOp &&
            !unlandedAdds.contains(record.pending.op.pagePublicId) &&
            !behindDelete(record))
        .toList(growable: false);
    final renumbering =
        list.where((record) => renumbersPages(record.pending.op)).firstOrNull;
    // Side changes, like renames, land before anything that renumbers.
    final sideChangesWaiting = records.any((record) =>
        record.entityKey.kind == EntitySyncKeyKind.pageDescriptor &&
        !unlandedAdds.contains(record.entityKey.pageId) &&
        !behindDelete(record) &&
        waiting(record));
    final next = records.any(_isOldPageChange)
        ? null
        : renames.where(sendable).firstOrNull ??
            (renumbering != null &&
                    sendable(renumbering) &&
                    !renames.any(waiting) &&
                    !sideChangesWaiting
                ? renumbering
                : null);
    final nextOp = next?.pending.op;
    final nextPage = nextOp?.pagePublicId;
    final others = records
        .where((record) =>
            !_isPageChange(record) &&
            sendable(record) &&
            !unlandedAdds.contains(record.entityKey.pageId) &&
            !behindDelete(record) &&
            // One change to a page's side or name per batch: the second
            // waits to be moved onto the revision the first lands at.
            !(nextOp is PagePatchOp &&
                record.entityKey == EntitySyncKey.pageDescriptor(nextPage!)))
        .toList(growable: false);

    final batchClientId = (others.firstOrNull ?? next)?.pending.clientId;
    if (batchClientId == null) return const <DurableOutboxRecord>[];
    final selected = <DurableOutboxRecord>[];
    bool fits(DurableOutboxRecord candidate) =>
        selected.length < _maxBatchSize &&
        serializedCloudBatchUtf8Bytes(
              strategyPublicId: strategyPublicId,
              clientId: batchClientId,
              ops: [...selected, candidate].map((record) => record.pending.op),
            ) <=
            maxCloudBatchBytes;
    final room = next?.pending.clientId == batchClientId ? 1 : 0;
    for (final candidate in others) {
      if (candidate.pending.clientId != batchClientId) continue;
      if (selected.length + room >= _maxBatchSize || !fits(candidate)) break;
      selected.add(candidate);
    }
    if (room == 1 && fits(next!)) {
      // A delete takes its page's last edits to the trash, and a copy on the
      // server takes its source page as it is then: either goes only once
      // all of that page's waiting work is in this batch ahead of it.
      final workPage = switch (nextOp) {
        PageDeleteOp() => nextPage,
        PageAddOp(:final copyContentFromPagePublicId) =>
          copyContentFromPagePublicId,
        _ => null,
      };
      final pageWork = workPage == null
          ? const <DurableOutboxRecord>[]
          : records.where((record) =>
              !_isPageChange(record) &&
              record.entityKey.pageId == workPage &&
              !behindDelete(record) &&
              waiting(record));
      if (pageWork.every(selected.contains)) selected.add(next);
    }
    return selected;
  }

  /// The revision [ack] says this device's own change moved its row to, or
  /// null when it cannot say the change was this device's. Only an applied
  /// answer can: a no-change answer carries the row's revision now, which
  /// may be a teammate's (an add sent again after its op record expired on
  /// the server is answered that way too).
  static int? _ownRevision(OpAck ack) =>
      ack is AppliedOpAck ? ack.revision : null;

  /// [delete], this device's delete of a page, landed: the renames and side
  /// changes made after it (see [_isBehindDelete]) go with the page, unsent.
  /// The user deleted the page, and nothing of them shows anywhere.
  Future<void> _dropEditsBehindDelete(DurableOutboxRecord delete) async {
    final behind = _isBehindDelete([delete]);
    final dropped = [
      for (final record in _recordsByStorageKey.values)
        if (record.accountId == delete.accountId &&
            record.strategyPublicId == delete.strategyPublicId &&
            record.storageKey != delete.storageKey &&
            record.status != DurableOutboxStatus.inFlight &&
            behind(record))
          record.storageKey,
    ];
    for (final storageKey in dropped) {
      await _removeRecordByStorageKey(storageKey);
    }
  }

  /// Whether a record is a rename or side change made after its page's
  /// delete in [list] (a strategy's page changes, in order) was. It waits
  /// behind the delete: once the delete lands it is dropped with the page
  /// (see [_dropEditsBehindDelete]); while the delete is refused it waits
  /// with it, and if the user discards the delete it goes as made.
  bool Function(DurableOutboxRecord) _isBehindDelete(
    List<DurableOutboxRecord> list,
  ) {
    final deletes = <String, DurableOutboxRecord>{};
    for (final record in list) {
      final op = record.pending.op;
      if (op is PageDeleteOp)
        deletes.putIfAbsent(op.pagePublicId, () => record);
    }
    if (deletes.isEmpty) return (_) => false;
    return (record) {
      if (_isPageChange(record)) {
        final delete = deletes[record.pending.op.pagePublicId];
        return delete != null &&
            record.pending.op is PagePatchOp &&
            _inListOrder(delete, record) < 0;
      }
      final delete = deletes[record.entityKey.pageId];
      return delete != null &&
          record.entityKey.kind == EntitySyncKeyKind.pageDescriptor &&
          !_isOldPageChange(record) &&
          record.createdAt.isAfter(delete.createdAt);
    };
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
      final ownRevision = _ownRevision(ack);
      if (ownRevision != null && _takesStrategyRevision(sent.pending.op)) {
        await _advanceOwnStrategyRevision(sent, ownRevision);
      }
      if ((sent.pending.op, ack.appliedRevision)
          case (StrategyPatchOp(:final payload), final revision?)
          when ack.isAck &&
              revision >
                  (_landedStrategyPatches[sent.strategyPublicId]?.revision ??
                      -1)) {
        _landedStrategyPatches[sent.strategyPublicId] =
            (payload: payload, revision: revision);
      }
      if (ack case AppliedOpAck(:final revision)
          when sent.pending.op is PagePatchOp) {
        await _advanceOwnPageRevision(sent, revision);
      }
      if ((ack.isAck, ownRevision ?? ack.appliedRevision)
          case (true, final revision?)
          when (_isPageChange(sent) || isPageChangeOp(sent.pending.op)) &&
              _isActive(sent.accountId, sent.strategyPublicId)) {
        _landedPageChanges.add((
          op: sent.pending.op,
          revision: revision,
          applied: ownRevision != null,
        ));
      }
      if (ack.isAck && sent.pending.op is PageDeleteOp) {
        await _dropEditsBehindDelete(sent);
      }
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

  /// Whether [accountId], whose batch was refused, can no longer edit
  /// [strategyPublicId]: a fresh read of its shell names a role that cannot
  /// edit, or is itself refused. applyBatch also answers FORBIDDEN to a
  /// batch bound to another account, which is not this. So the read must
  /// run as [accountId], with the session unchanged until it answers: a
  /// refusal read as anyone else says nothing about this account. A read
  /// that fails otherwise could not tell either.
  Future<bool> _editAccessIsConfirmedGone(
    String strategyPublicId, {
    required String accountId,
  }) async {
    final session = ref.read(authProvider);
    if (!_canSendAs(accountId)) return false;
    bool gone;
    try {
      final shell = await _repo.fetchShell(strategyPublicId);
      gone =
          !StrategyCapabilities.fromCloudRole(shell.header.role).canEditPages;
    } catch (error) {
      gone = isTypedConvexForbiddenError(error);
    }
    return gone && !_isDisposed && identical(ref.read(authProvider), session);
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

  /// Drops [accountId]'s changes to [strategyPublicId] that are waiting,
  /// after the server refused that account the strategy and the user chose
  /// to discard them. A change being sent right now is left to its answer:
  /// it may have landed. Returns whether every one was removed.
  Future<bool> discardUnsendableWork(
    String strategyPublicId, {
    required String accountId,
  }) async {
    var removedAll = false;
    await _serializeWrite(() async {
      final storageKeys = _recordsByStorageKey.values
          .where((record) =>
              record.accountId == accountId &&
              record.strategyPublicId == strategyPublicId &&
              record.status != DurableOutboxStatus.inFlight)
          .map((record) => record.storageKey)
          .toList(growable: false);
      try {
        for (final storageKey in storageKeys) {
          await _removeRecordByStorageKey(storageKey);
        }
        removedAll = true;
      } catch (error, stackTrace) {
        _recordPersistenceFailure(error, stackTrace);
      } finally {
        _pruneCanvasOpIds();
      }
      // The refusal described work that is gone now; keeping its error
      // would hold the editor's exit for nothing.
      _refreshActiveQueueView(clearError: removedAll);
    });
    return removedAll;
  }

  /// Drops every outbox record of [strategyPublicId] for the current
  /// account: a strategy the server no longer has, discarded by the user,
  /// or one they deleted on this device.
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
              (record.entityKey.pageId == pageId ||
                  (_isPageChange(record) &&
                      record.pending.op.pagePublicId == pageId)) &&
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
      // Work the dropped work held back can go now.
      _scheduleFlush(flushImmediately: true);
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
  /// has failed too often is paused until the user retries it. With [pause]
  /// every record is paused at once.
  Future<void> _restoreRecordsAfterFailure(
    List<DurableOutboxRecord> batch, {
    required String lastError,
    bool countsAsFailure = true,
    bool pause = false,
  }) {
    return _serializeWrite(
      () => _restoreRecordsAfterFailureLocked(
        batch,
        lastError: lastError,
        countsAsFailure: countsAsFailure,
        pause: pause,
      ),
    );
  }

  Future<void> _restoreRecordsAfterFailureLocked(
    List<DurableOutboxRecord> batch, {
    required String lastError,
    required bool countsAsFailure,
    required bool pause,
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
        final isPaused = pause || pending.attempts >= _maxAttempts;
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
      pageChangeSequence: current?.pageChangeSequence,
      waitsForPageAdd: current?.waitsForPageAdd ?? false,
      pageCopyKeys: current?.pageCopyKeys,
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
    if (!record.waitsForPageAdd && _waitsForPageAdd(record)) {
      record = record.copyWith(waitsForPageAdd: true);
    }
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

  /// [records] with every page copy that did not finish saving held back
  /// (see DurableOutboxRecord.pageCopyKeys): a write cut short can leave the
  /// add and only some of its items on disk, each readable. Such an add, and
  /// the items of it that are there, wait in attention with
  /// [incompletePageCopyMessage] instead of being sent as a smaller copy.
  /// [records] itself when nothing is held.
  Map<String, DurableOutboxRecord> _holdIncompletePageCopies(
    Map<String, DurableOutboxRecord> records,
  ) {
    final keysByStrategy = <(String, String), Set<String>>{};
    Set<String> keysOf(DurableOutboxRecord record) =>
        keysByStrategy.putIfAbsent(
          (record.accountId, record.strategyPublicId),
          () => {
            for (final other in records.values)
              if (other.accountId == record.accountId &&
                  other.strategyPublicId == record.strategyPublicId)
                '${other.entityKey}',
          },
        );
    Map<String, DurableOutboxRecord>? held;
    for (final add in records.values) {
      final copyKeys = add.pageCopyKeys;
      if (copyKeys == null ||
          add.status == DurableOutboxStatus.attention ||
          add.pending.op is! PageAddOp) {
        continue;
      }
      final present = keysOf(add);
      if (copyKeys.every(present.contains)) continue;
      final message = incompletePageCopyMessage(
        (add.pending.op as PageAddOp).payload['name'] as String? ?? 'a page',
      );
      held ??= Map.of(records);
      for (final record in [
        add,
        for (final other in records.values)
          if (other.accountId == add.accountId &&
              other.strategyPublicId == add.strategyPublicId &&
              copyKeys.contains('${other.entityKey}'))
            other,
      ]) {
        held[record.storageKey] = record.copyWith(
          status: DurableOutboxStatus.attention,
          lastError: message,
        );
      }
    }
    return held ?? records;
  }

  /// Whether [record] is work for a page whose add, made on this device,
  /// is still in its strategy's page changes (see
  /// DurableOutboxRecord.waitsForPageAdd).
  bool _waitsForPageAdd(DurableOutboxRecord record) {
    final pageId = record.entityKey.pageId;
    if (pageId == null || _isPageChange(record)) return false;
    return _recordsByStorageKey.values.any((other) =>
        _isPageChange(other) &&
        other.accountId == record.accountId &&
        other.strategyPublicId == record.strategyPublicId &&
        other.pending.op is PageAddOp &&
        other.pending.op.pagePublicId == pageId);
  }

  Future<void> _removeRecordByStorageKey(String storageKey) async {
    // A copy's item removed here on purpose (cancelled before it was sent,
    // say) leaves its add's list first: missing from it, it would read as
    // a copy cut short. Done before the removal, a crash between the two
    // leaves an item the add no longer names, which is still sent.
    final removed = _recordsByStorageKey[storageKey];
    if (removed != null) {
      final key = '${removed.entityKey}';
      for (final add in _recordsByStorageKey.values.toList()) {
        final copyKeys = add.pageCopyKeys;
        if (copyKeys == null ||
            add.accountId != removed.accountId ||
            add.strategyPublicId != removed.strategyPublicId ||
            !copyKeys.contains(key)) {
          continue;
        }
        await _putRecord(add.copyWith(
          pageCopyKeys: [
            for (final other in copyKeys)
              if (other != key) other,
          ],
        ));
      }
    }
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
    final now = DateTime.now();
    final candidates = _backgroundBatches(
      accountId,
      ignoreBackoff: true,
      now: now,
    ).expand((batch) => batch).toList(growable: false);
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
    final now = DateTime.now();
    final candidates = _backgroundBatches(
      accountId,
      ignoreBackoff: ignoreBackoff,
      now: now,
    ).expand((batch) => batch).toList(growable: false)
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

  /// The batch each strategy other than the active one would send now
  /// (see [_selectBatch]), for those with one. Work that waits on other
  /// work, like a page change behind one refused, is not here, so the
  /// drain does not spin on it.
  Iterable<List<DurableOutboxRecord>> _backgroundBatches(
    String accountId, {
    required bool ignoreBackoff,
    required DateTime now,
  }) {
    final activeStrategyId = state.strategyPublicId;
    final strategies = {
      for (final record in _recordsByStorageKey.values)
        if (record.accountId == accountId &&
            record.strategyPublicId != activeStrategyId &&
            _sendableNow(record, ignoreBackoff: ignoreBackoff, now: now))
          record.strategyPublicId,
    };
    return [
      for (final strategyPublicId in strategies)
        _selectBatch(
          accountId: accountId,
          strategyPublicId: strategyPublicId,
          ignoreBackoff: ignoreBackoff,
          now: now,
        ),
    ].where((batch) => batch.isNotEmpty);
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
          copyContentFromPagePublicId: existing.copyContentFromPagePublicId,
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
        // The waiting change was made against its revision, and a strategy
        // patch has no field merge: carried into a newer edit, it keeps
        // that revision, so a teammate's header that landed since is
        // refused and the user asked, never written over in silence. (It
        // moves on past this device's own changes as they land: see
        // _advanceOwnStrategyRevision.)
        return StrategyPatchOp(
          opId: replacementOpId,
          payload: {...existing.payload, ...desired.payload},
          expectedStrategyRevision: existing.expectedStrategyRevision,
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
    // Merged onto the server's version it can't stand (or can't be read,
    // undrawableWorkMessage): the user's version replaces the server's
    // whole.
    if (refusal == OpRejectionReason.mergeInvalid.wireName ||
        refusal == undrawableWorkMessage) {
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

  /// Whether [op] is checked against the strategy's revision, and moves it
  /// on when it lands: a strategy patch, or a page added, deleted or
  /// reordered (see applyStrategyOp and applyPageOp in convex/ops.ts).
  static bool _takesStrategyRevision(StrategyOp op) =>
      op is StrategyPatchOp ||
      op is PageAddOp ||
      op is PageDeleteOp ||
      op is PageReorderOp;

  /// [sent], this device's own change to the strategy, landed and moved the
  /// strategy from [revision] - 1 to [revision]. A waiting change made
  /// against [revision] - 1 knows everything in [revision] (this device
  /// made it), so it now waits against [revision]: a map changed while a
  /// page reorder was being sent is not refused for the reorder. Only an
  /// answer to this device's own change moves waiting work on. A revision
  /// read live says nothing about who made it, and one a teammate made
  /// leaves the work to be refused, so the user is asked. Work being sent,
  /// or already refused, is left as it is.
  Future<void> _advanceOwnStrategyRevision(
    DurableOutboxRecord sent,
    int revision,
  ) async {
    final waiting = _recordsByStorageKey.values
        .where((record) =>
            record.accountId == sent.accountId &&
            record.strategyPublicId == sent.strategyPublicId &&
            (record.status == DurableOutboxStatus.queued ||
                record.status == DurableOutboxStatus.paused) &&
            _takesStrategyRevision(record.pending.op) &&
            record.pending.op.expectedRevision == revision - 1)
        .toList(growable: false);
    for (final record in waiting) {
      final pending = record.pending;
      await _putRecord(record.copyWith(
        pending: PendingOp(
          op: _atStrategyRevision(pending.op, revision),
          clientId: pending.clientId,
          attempts: pending.attempts,
          lastAttemptAt: pending.lastAttemptAt,
        ),
        updatedAt: DateTime.now(),
      ));
    }
  }

  /// [sent], this device's own change to a page's name or side, landed and
  /// moved the page from [revision] - 1 to [revision]. Another such change
  /// to the page made against [revision] - 1 knows everything in
  /// [revision], so it now waits against [revision], as
  /// [_advanceOwnStrategyRevision] does for the strategy: a rename and a
  /// side change made offline both land.
  Future<void> _advanceOwnPageRevision(
    DurableOutboxRecord sent,
    int revision,
  ) async {
    final pageId = sent.pending.op.pagePublicId;
    final waiting = _recordsByStorageKey.values
        .where((record) =>
            record.accountId == sent.accountId &&
            record.strategyPublicId == sent.strategyPublicId &&
            record.storageKey != sent.storageKey &&
            (record.status == DurableOutboxStatus.queued ||
                record.status == DurableOutboxStatus.paused) &&
            record.pending.op is PagePatchOp &&
            record.pending.op.pagePublicId == pageId &&
            record.pending.op.expectedRevision == revision - 1)
        .toList(growable: false);
    for (final record in waiting) {
      final pending = record.pending;
      final op = pending.op as PagePatchOp;
      await _putRecord(record.copyWith(
        pending: PendingOp(
          op: PagePatchOp(
            opId: op.opId,
            pagePublicId: op.pagePublicId,
            payload: op.payload,
            expectedPageRevision: revision,
          ),
          clientId: pending.clientId,
          attempts: pending.attempts,
          lastAttemptAt: pending.lastAttemptAt,
        ),
        updatedAt: DateTime.now(),
      ));
    }
  }

  /// [op] (see [_takesStrategyRevision]) made against the strategy at
  /// [revision]. It keeps its op id: it is the same change.
  static StrategyOp _atStrategyRevision(StrategyOp op, int revision) =>
      switch (op) {
        StrategyPatchOp(:final opId, :final payload) => StrategyPatchOp(
            opId: opId,
            payload: payload,
            expectedStrategyRevision: revision,
          ),
        PageAddOp(
          :final opId,
          :final pagePublicId,
          :final payload,
          :final sortIndex,
          :final copyContentFromPagePublicId,
        ) =>
          PageAddOp(
            opId: opId,
            pagePublicId: pagePublicId,
            payload: payload,
            sortIndex: sortIndex,
            expectedStrategyRevision: revision,
            copyContentFromPagePublicId: copyContentFromPagePublicId,
          ),
        PageDeleteOp(:final opId, :final pagePublicId) => PageDeleteOp(
            opId: opId,
            pagePublicId: pagePublicId,
            expectedStrategyRevision: revision,
          ),
        PageReorderOp(:final opId, :final pagePublicId, :final sortIndex) =>
          PageReorderOp(
            opId: opId,
            pagePublicId: pagePublicId,
            sortIndex: sortIndex,
            expectedStrategyRevision: revision,
          ),
        _ => throw ArgumentError.value(op, 'op', 'Takes no strategy revision'),
      };

  /// [op], made to wait behind [predecessor], which is sent first. When the
  /// predecessor is this canvas's own work ([drawn]) and merges by field,
  /// [op]'s merge also names every field the predecessor does, with the
  /// user's current values: a field the user set back meanwhile is written
  /// again, and should the predecessor be refused and the user keep theirs,
  /// this one change still carries all of it. Its base, for those fields, is
  /// what the predecessor writes, which the server holds once it lands.
  /// Behind a whole write, [op] is whole too. Work the canvas never drew (recovered after a restart) is left out:
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
    if (merge == null || writtenPayload == null || !drawn) return op;
    // Behind a whole write of the canvas's own, the server holds exactly
    // what the canvas drew once it lands: this one is whole too, so a field
    // the user set back meanwhile is written again.
    if (written == null) return op.withMerge(null);
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
      PageAddOp(
        :final pagePublicId,
        :final payload,
        :final sortIndex,
        :final copyContentFromPagePublicId,
      ) =>
        PageAddOp(
          opId: opId,
          pagePublicId: pagePublicId,
          payload: payload,
          sortIndex: sortIndex,
          expectedStrategyRevision: revision,
          copyContentFromPagePublicId: copyContentFromPagePublicId,
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
    // Nothing else here can land while edit access is gone, so that reason
    // speaks for all of it.
    final refusedForAccess = paused.keys.where(
      (key) => recordFor(key)?.lastError == editAccessRemovedMessage,
    );
    if (refusedForAccess.isNotEmpty) {
      return refusedForAccess.length < paused.length + attention.length
          ? '$editAccessRemovedMessage $otherWorkNeedsAttentionNote'
          : editAccessRemovedMessage;
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
      // in the trash), or held because it no longer fits the page, keeps
      // that reason, so the sync button does not call it a conflict. Other attention beside it is noted so it is not left
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
            reason == undrawableWorkMessage ||
            reason == pageDeletedMessage ||
            isIncompletePageCopyReason(reason)) {
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
            ? withOtherWorkNeedsAttentionNote(specificReason)
            : specificReason;
      }
      return 'Some saved work needs attention.';
    }
    if (paused.isNotEmpty) return 'Some saved work is paused after retries.';
    return null;
  }
}
