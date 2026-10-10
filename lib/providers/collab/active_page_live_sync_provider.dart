import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:math' show max;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/const/sort_index_order.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/field_merge.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_conflict_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:uuid/uuid.dart';

class ActivePageLiveSyncState {
  const ActivePageLiveSyncState({
    this.strategyPublicId,
    this.activePageId,
    this.hydratedPageId,
    this.hydratedEntityKeys = const <EntitySyncKey>{},
    this.remoteBaseRevisionByEntity = const <EntitySyncKey, int>{},
    this.overlayByEntityKey = const <EntitySyncKey, ActivePageOverlayEntry>{},
    this.lastAckBatch = const <AckedEntityIntent>[],
  });

  final String? strategyPublicId;
  final String? activePageId;
  final String? hydratedPageId;
  final Set<EntitySyncKey> hydratedEntityKeys;
  final Map<EntitySyncKey, int> remoteBaseRevisionByEntity;
  final Map<EntitySyncKey, ActivePageOverlayEntry> overlayByEntityKey;
  final List<AckedEntityIntent> lastAckBatch;

  ActivePageLiveSyncState copyWith({
    String? strategyPublicId,
    String? activePageId,
    bool clearActivePageId = false,
    String? hydratedPageId,
    bool clearHydratedPage = false,
    Set<EntitySyncKey>? hydratedEntityKeys,
    Map<EntitySyncKey, int>? remoteBaseRevisionByEntity,
    Map<EntitySyncKey, ActivePageOverlayEntry>? overlayByEntityKey,
    List<AckedEntityIntent>? lastAckBatch,
  }) {
    return ActivePageLiveSyncState(
      strategyPublicId: strategyPublicId ?? this.strategyPublicId,
      activePageId:
          clearActivePageId ? null : (activePageId ?? this.activePageId),
      hydratedPageId:
          clearHydratedPage ? null : (hydratedPageId ?? this.hydratedPageId),
      hydratedEntityKeys: hydratedEntityKeys ?? this.hydratedEntityKeys,
      remoteBaseRevisionByEntity:
          remoteBaseRevisionByEntity ?? this.remoteBaseRevisionByEntity,
      overlayByEntityKey: overlayByEntityKey ?? this.overlayByEntityKey,
      lastAckBatch: lastAckBatch ?? this.lastAckBatch,
    );
  }
}

/// Bumped whenever the lineup group memory learns a group (see
/// [ActivePageLiveSyncNotifier.lineupGroupOf]), so what reads it can read it
/// again.
final lineupGroupMemoryRevisionProvider = StateProvider<int>((ref) => 0);

final activePageLiveSyncProvider =
    NotifierProvider<ActivePageLiveSyncNotifier, ActivePageLiveSyncState>(
  ActivePageLiveSyncNotifier.new,
);

class ActivePageLiveSyncNotifier extends Notifier<ActivePageLiveSyncState> {
  // Live reads can advance while local work blocks rehydration. Outbound diffs
  // must stay based on the server state that was actually loaded into canvas.
  final Map<EntitySyncKey, _NormalizedEntity> _hydratedBaseByEntityKey = {};
  final Set<EntitySyncKey> _remoteAdoptionPending = {};

  /// Each element's place in its canvas list right after the page was last
  /// hydrated, to tell a local restack from the order hydration drew.
  final Map<EntitySyncKey, int> _hydratedPositionByKey = {};

  /// Items the user holds that the server deleted: still on screen until the
  /// hold ends, but no longer ordered against anything on the server.
  final Set<EntitySyncKey> _heldDeletedKeys = {};

  /// Per page, the lineup group each lineup and spot was last drawn from or
  /// written to (see cloudLineupRows), so a group keeps its id and its
  /// lineups while the canvas changes under it. Per page because a page
  /// duplicated before cloud sync repeats its lineup ids. Never forgotten:
  /// an undo can bring back a lineup long after its row moved on.
  final Map<String, Map<String, String>> _lineupGroupOfByPage = {};

  /// Records the groups a canvas of [pageId] about to be drawn from cloud
  /// rows uses.
  void noteLineupGroups(String pageId, Map<String, String> groupOf) {
    _rememberLineupGroups(_lineupGroupOfByPage[pageId] ??= {}, groupOf);
  }

  void _rememberLineupGroups(
    Map<String, String> memory,
    Map<String, String> groupOf,
  ) {
    var learned = false;
    for (final MapEntry(:key, :value) in groupOf.entries) {
      if (memory[key] != value) {
        memory[key] = value;
        learned = true;
      }
    }
    if (learned) ref.read(lineupGroupMemoryRevisionProvider.notifier).state++;
  }

  /// The server's version of [key] the canvas was drawn from, which local
  /// edits to it were made against: its revision, and its payload (null
  /// when it was deleted). Null when the canvas was drawn without it.
  ({int revision, Object? payload})? hydratedBase(EntitySyncKey key) {
    final base = _hydratedBaseByEntityKey[key];
    if (base == null) return null;
    return (
      revision: base.revision,
      payload: base.deleted ? null : base.payload
    );
  }

  /// The lineup group [itemId] (a lineup, origin or landing) on [pageId]
  /// was last in.
  String? lineupGroupOf(String pageId, String itemId) =>
      _lineupGroupOfByPage[pageId]?[itemId];

  @override
  ActivePageLiveSyncState build() {
    return const ActivePageLiveSyncState();
  }

  void reset() {
    _forgetDrawnState();
    state = const ActivePageLiveSyncState();
  }

  /// Drops the bases and overlays: the canvas is drawn fresh next, from the
  /// server, without any work still queued. The queue then marks that
  /// work's acks restored.
  void _forgetDrawnState() {
    _hydratedBaseByEntityKey.clear();
    _remoteAdoptionPending.clear();
    _hydratedPositionByKey.clear();
    _heldDeletedKeys.clear();
    if (ref.exists(strategyOpQueueProvider)) {
      ref.read(strategyOpQueueProvider.notifier).forgetCanvasWork();
    }
  }

  void setStateForTest(ActivePageLiveSyncState nextState) {
    state = nextState;
  }

  void setContext({
    required String? strategyPublicId,
    required String? activePageId,
  }) {
    final strategyChanged = strategyPublicId != state.strategyPublicId;
    final contextChanged = strategyPublicId != state.strategyPublicId ||
        activePageId != state.activePageId;
    if (strategyChanged) _forgetDrawnState();
    state = state.copyWith(
      strategyPublicId: strategyPublicId,
      activePageId: activePageId,
      clearActivePageId: activePageId == null,
      clearHydratedPage: contextChanged,
      hydratedEntityKeys:
          contextChanged ? const <EntitySyncKey>{} : state.hydratedEntityKeys,
      remoteBaseRevisionByEntity: strategyPublicId == state.strategyPublicId
          ? state.remoteBaseRevisionByEntity
          : const <EntitySyncKey, int>{},
      overlayByEntityKey: strategyPublicId == state.strategyPublicId
          ? state.overlayByEntityKey
          : const <EntitySyncKey, ActivePageOverlayEntry>{},
    );
  }

  void markPageUnhydrated({
    required String strategyPublicId,
    required String pageId,
  }) {
    setContext(strategyPublicId: strategyPublicId, activePageId: pageId);
    state = state.copyWith(
      clearHydratedPage: true,
      hydratedEntityKeys: const <EntitySyncKey>{},
    );
  }

  /// [keepBaseFor] names entities the canvas did not take from [snapshot]
  /// (the user is holding them). They keep the base they were drawn from, so
  /// an edit the user commits to one is checked against the version they saw.
  void markPageHydrated({
    required String strategyPublicId,
    required String pageId,
    required RemoteEditorSnapshot snapshot,
    Set<EntitySyncKey> keepBaseFor = const {},
  }) {
    setContext(strategyPublicId: strategyPublicId, activePageId: pageId);
    final matchesPage = snapshot.header.publicId == strategyPublicId &&
        snapshot.activePage?.page.publicId == pageId;
    final remoteEntities = {
      if (matchesPage) ..._normalizedRemoteEntities(snapshot, pageId),
    };
    _heldDeletedKeys
      ..removeWhere((key) => key.pageId == pageId)
      ..addAll({
        for (final key in keepBaseFor)
          if (remoteEntities[key]?.deleted ?? true) key,
      });
    for (final key in keepBaseFor) {
      final drawnBase = _hydratedBaseByEntityKey[key];
      if (drawnBase == null) {
        remoteEntities.remove(key);
        continue;
      }
      // Its content and revision stay as drawn; its place is where the
      // merge put it on screen, the server's.
      final serverSortIndex = remoteEntities[key]?.sortIndex;
      remoteEntities[key] = _NormalizedEntity(
        key: key,
        overlayEntityType: drawnBase.overlayEntityType,
        payload: drawnBase.payload,
        sortIndex: serverSortIndex ?? drawnBase.sortIndex,
        revision: drawnBase.revision,
        deleted: drawnBase.deleted,
      );
    }
    _hydratedBaseByEntityKey.removeWhere((key, _) => key.pageId == pageId);
    _hydratedBaseByEntityKey.addAll(remoteEntities);
    _remoteAdoptionPending.removeWhere((key) => key.pageId == pageId);
    final remoteRevisions = Map<EntitySyncKey, int>.from(
      state.remoteBaseRevisionByEntity,
    )..removeWhere((key, _) => key.pageId == pageId);
    for (final entry in remoteEntities.entries) {
      remoteRevisions[entry.key] = entry.value.revision;
    }
    _hydratedPositionByKey
      ..removeWhere((key, _) => key.pageId == pageId)
      ..addAll({
        for (final (position, envelope)
            in _collectLocalElementEnvelopes().indexed)
          EntitySyncKey.element(pageId, envelope.publicId): position,
      });
    state = state.copyWith(
      hydratedPageId: pageId,
      hydratedEntityKeys: _normalizedLocalEntities(pageId).keys.toSet(),
      remoteBaseRevisionByEntity: remoteRevisions,
    );
  }

  /// Takes [pageId] back as the hydrated page, with the base it was drawn
  /// from and the acks recorded since: the canvas never left it, only the
  /// live read did, as when a teammate deleted it and it was restored. Its
  /// unsent work is diffed against that base again.
  void resumePage({
    required String strategyPublicId,
    required String pageId,
  }) {
    setContext(strategyPublicId: strategyPublicId, activePageId: pageId);
    state = state.copyWith(hydratedPageId: pageId);
  }

  /// The entities of [pageId] whose server copy in [snapshot] differs from the
  /// one the canvas last drew.
  Set<EntitySyncKey> remoteChangesSinceHydration(
    RemoteEditorSnapshot snapshot,
    String pageId,
  ) {
    _NormalizedEntity? live(_NormalizedEntity? entity) =>
        entity == null || entity.deleted ? null : entity;
    final remote = _normalizedRemoteEntities(snapshot, pageId);
    final keys = {
      ...remote.keys,
      ..._hydratedBaseByEntityKey.keys.where((key) => key.pageId == pageId),
    };
    return {
      for (final key in keys)
        if (!_sameLiveEntity(
          live(remote[key]),
          live(_hydratedBaseByEntityKey[key]),
        ))
          key,
    };
  }

  bool _sameLiveEntity(_NormalizedEntity? a, _NormalizedEntity? b) =>
      a == null ? b == null : b != null && _entitiesEquivalent(a, b);

  /// Drops [pageId]'s overlays that no op in the queue carries any more and
  /// that the server's copy on hand already shows.
  ///
  /// An overlay holds local intent until the server has it. Once its op has
  /// landed and the snapshot shows it, the server's snapshot is the truth,
  /// and it may already hold a teammate's newer change to that entity;
  /// painting the overlay would show the older local version and the next
  /// sync would write it back. Until the snapshot shows it (its refresh after
  /// the ack is still on its way), the overlay stays, or the page would paint
  /// the old version for a moment. Call this before projecting a page for
  /// hydration. Acks usually clear overlays in syncLocalPage, but that skips a
  /// page that is being rehydrated or is not the active one. A page only
  /// rehydrates once its local edits are queued (the session waits for
  /// pending cloud sync), so this never drops unsent work.
  void dropSatisfiedOverlays(String pageId) {
    final queue = ref.read(strategyOpQueueProvider);
    bool isPending(EntitySyncKey key) =>
        queue.queuedByEntityKey.containsKey(key) ||
        queue.inFlightByEntityKey.containsKey(key) ||
        queue.successorByEntityKey.containsKey(key) ||
        queue.pausedByEntityKey.containsKey(key) ||
        queue.attentionByEntityKey.containsKey(key);
    final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
    final remote = snapshot == null
        ? const <EntitySyncKey, _NormalizedEntity>{}
        : _normalizedRemoteEntities(snapshot, pageId);
    // Where the overlay's work landed: the revision its last ack names,
    // read from the queue itself, since the session records acks only after
    // the save state that can bring a reapply here has already changed (see
    // recordAckBatch), and the overlay's base, which acks recorded earlier
    // moved there. A row the server no longer has shows nothing to wait
    // for.
    final landedRevisions = {
      for (final acked in queue.lastAckBatch)
        if (acked.ack.appliedRevision case final revision?)
          acked.entityKey: revision,
    };
    bool shownByServer(EntitySyncKey key, ActivePageOverlayEntry overlay) {
      final landedAt = max(
        overlay.baseRevision ?? 0,
        landedRevisions[key] ?? 0,
      );
      final row = remote[key];
      return row == null || row.revision >= landedAt;
    }

    final overlays = Map<EntitySyncKey, ActivePageOverlayEntry>.from(
      state.overlayByEntityKey,
    )..removeWhere((key, overlay) =>
        key.pageId == pageId && !isPending(key) && shownByServer(key, overlay));
    if (overlays.length == state.overlayByEntityKey.length) return;
    state = state.copyWith(overlayByEntityKey: overlays);
  }

  /// Whether the server lacks work the canvas holds for [pageId]: an entity
  /// that differs from the one last drawn from (or accepted by) the server,
  /// or an op for the page still in the queue.
  bool hasUnsentWork(String pageId) {
    final local = _normalizedLocalEntities(pageId);
    final keys = {
      ...local.keys,
      ..._hydratedBaseByEntityKey.keys.where((key) => key.pageId == pageId),
    };
    if (keys.any(
      (key) => !_entitiesEquivalent(local[key], _hydratedBaseByEntityKey[key]),
    )) {
      return true;
    }
    final queue = ref.read(strategyOpQueueProvider);
    return [
      queue.queuedByEntityKey,
      queue.inFlightByEntityKey,
      queue.successorByEntityKey,
      queue.pausedByEntityKey,
      queue.attentionByEntityKey,
    ].any((intents) => intents.keys.any((key) => key.pageId == pageId));
  }

  bool hasOverlayForPage(String pageId) {
    return state.overlayByEntityKey.keys.any((key) => key.pageId == pageId);
  }

  void recordAckBatch(List<AckedEntityIntent> intents) {
    final overlays = Map<EntitySyncKey, ActivePageOverlayEntry>.from(
      state.overlayByEntityKey,
    );
    final remoteRevisions = Map<EntitySyncKey, int>.from(
      state.remoteBaseRevisionByEntity,
    );
    for (final intent in intents) {
      final revision = intent.ack.appliedRevision;
      final key = intent.entityKey;
      if (revision == null) {
        continue;
      }
      final accepted = _normalizedAcceptedEntity(
        key: key,
        op: intent.op,
        revision: revision,
      );
      if (accepted == null) continue;

      // The user's newer edit to it, if any, follows the op onto this
      // revision, as the queue's successor does.
      final overlay = overlays[key];
      if (overlay != null) {
        overlays[key] = overlay.copyWith(
          baseRevision: revision,
          baseDeleted: accepted.deleted,
        );
      }
      // The canvas was drawn without an op recovered from the outbox and
      // still shows the version before it. Its landing is a server change
      // like a teammate's: the next merge draws it, and until then an edit
      // to the item is checked against the version on screen, so it
      // conflicts instead of replacing the recovered work.
      if (intent.restored) continue;
      _hydratedBaseByEntityKey[key] = accepted;
      remoteRevisions[key] = revision;
    }
    state = state.copyWith(
      overlayByEntityKey: overlays,
      remoteBaseRevisionByEntity: remoteRevisions,
      lastAckBatch: intents,
    );
  }

  _NormalizedEntity? _normalizedAcceptedEntity({
    required EntitySyncKey key,
    required StrategyOp op,
    required int revision,
  }) {
    final previous = _hydratedBaseByEntityKey[key];
    return switch (op) {
      PagePatchOp(:final payload) => _NormalizedEntity(
          key: key,
          overlayEntityType: ActivePageOverlayEntityType.pageDescriptor,
          // The canvas tracks side only. Rename acks must not replace that
          // baseline, or introduce fields the canvas never compares.
          payload: <String, dynamic>{
            if (previous != null) ..._decodeObject(previous.payload),
            if (payload.containsKey('isAttack'))
              'isAttack': payload['isAttack'],
          },
          sortIndex: null,
          revision: revision,
          deleted: false,
        ),
      PageContentPatchOp(:final settings) => _NormalizedEntity(
          key: key,
          overlayEntityType: ActivePageOverlayEntityType.pageContent,
          payload: <String, dynamic>{'settings': settings},
          sortIndex: null,
          revision: revision,
          deleted: false,
        ),
      ElementAddOp(:final payload, :final sortIndex) ||
      ElementPatchOp(:final payload?, :final sortIndex?) =>
        _NormalizedEntity(
          key: key,
          overlayEntityType: ActivePageOverlayEntityType.element,
          payload: payload,
          sortIndex: sortIndex,
          revision: revision,
          deleted: false,
        ),
      ElementPatchOp(:final payload, :final sortIndex) when previous != null =>
        _NormalizedEntity(
          key: key,
          overlayEntityType: ActivePageOverlayEntityType.element,
          payload: payload ?? previous.payload,
          sortIndex: sortIndex ?? previous.sortIndex,
          revision: revision,
          deleted: false,
        ),
      ElementReorderOp(:final sortIndex) when previous != null =>
        _NormalizedEntity(
          key: key,
          overlayEntityType: ActivePageOverlayEntityType.element,
          payload: previous.payload,
          sortIndex: sortIndex,
          revision: revision,
          deleted: previous.deleted,
        ),
      ElementDeleteOp() when previous != null => _NormalizedEntity(
          key: key,
          overlayEntityType: ActivePageOverlayEntityType.element,
          payload: previous.payload,
          sortIndex: previous.sortIndex,
          revision: revision,
          deleted: true,
        ),
      LineupAddOp(:final payload, :final sortIndex) ||
      LineupPatchOp(:final payload?, :final sortIndex?) =>
        _NormalizedEntity(
          key: key,
          overlayEntityType: ActivePageOverlayEntityType.lineup,
          payload: payload,
          sortIndex: sortIndex,
          revision: revision,
          deleted: false,
        ),
      LineupPatchOp(:final payload, :final sortIndex) when previous != null =>
        _NormalizedEntity(
          key: key,
          overlayEntityType: ActivePageOverlayEntityType.lineup,
          payload: payload ?? previous.payload,
          sortIndex: sortIndex ?? previous.sortIndex,
          revision: revision,
          deleted: false,
        ),
      LineupReorderOp(:final sortIndex) when previous != null =>
        _NormalizedEntity(
          key: key,
          overlayEntityType: ActivePageOverlayEntityType.lineup,
          payload: previous.payload,
          sortIndex: sortIndex,
          revision: revision,
          deleted: previous.deleted,
        ),
      LineupDeleteOp() when previous != null => _NormalizedEntity(
          key: key,
          overlayEntityType: ActivePageOverlayEntityType.lineup,
          payload: previous.payload,
          sortIndex: previous.sortIndex,
          revision: revision,
          deleted: true,
        ),
      _ => null,
    };
  }

  /// Stops local projection and reconciliation for explicitly discarded work
  /// until the affected page has loaded the authoritative remote snapshot.
  void adoptRemoteForEntities(
    Set<EntitySyncKey> entityKeys, {
    String? hydratedPageId,
  }) {
    if (entityKeys.isEmpty) return;
    final overlays = Map<EntitySyncKey, ActivePageOverlayEntry>.from(
      state.overlayByEntityKey,
    );
    for (final key in entityKeys) {
      overlays.remove(key);
      if (key.pageId != null && key.pageId != hydratedPageId) {
        _remoteAdoptionPending.add(key);
      } else {
        _remoteAdoptionPending.remove(key);
      }
    }
    state = state.copyWith(overlayByEntityKey: overlays);
  }

  Map<EntitySyncKey, StrategyOp>? syncLocalPage({
    required String strategyPublicId,
    required String pageId,
  }) {
    setContext(strategyPublicId: strategyPublicId, activePageId: pageId);
    if (state.hydratedPageId != pageId) {
      _debugLog('sync.skip page=$pageId reason=page_not_hydrated');
      return null;
    }
    final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
    final remotePage = snapshot?.activePage;
    if (snapshot == null ||
        snapshot.header.publicId != strategyPublicId ||
        remotePage == null ||
        remotePage.page.publicId != pageId) {
      _debugLog(
        'sync.skip page=$pageId reason=missing_matching_remote_base',
      );
      return null;
    }

    final queueState = ref.read(strategyOpQueueProvider);
    final remoteEntities = _normalizedRemoteEntities(snapshot, pageId);
    final localEntities = _normalizedLocalEntities(pageId);

    final pageKeys = <EntitySyncKey>{
      ...remoteEntities.keys,
      ...localEntities.keys,
      ..._hydratedBaseByEntityKey.keys.where((key) => key.pageId == pageId),
      ...state.overlayByEntityKey.keys.where((key) => key.pageId == pageId),
      ...queueState.queuedByEntityKey.keys.where((key) => key.pageId == pageId),
      ...queueState.inFlightByEntityKey.keys
          .where((key) => key.pageId == pageId),
      ...queueState.successorByEntityKey.keys
          .where((key) => key.pageId == pageId),
      ..._remoteAdoptionPending.where((key) => key.pageId == pageId),
    };

    final nextOverlay = Map<EntitySyncKey, ActivePageOverlayEntry>.from(
      state.overlayByEntityKey,
    );
    final retainedDesiredOps = <EntitySyncKey, StrategyOp>{};
    final settledAttention = <EntitySyncKey>{};

    for (final key in pageKeys) {
      if (_remoteAdoptionPending.contains(key)) {
        nextOverlay.remove(key);
        _debugLog('overlay.remove $key reason=adopting_remote');
        continue;
      }
      final remote = remoteEntities[key];
      final local = localEntities[key];
      final hydratedBase = _hydratedBaseByEntityKey[key];
      final hasQueued = queueState.queuedByEntityKey.containsKey(key);
      final hasInFlight = queueState.inFlightByEntityKey.containsKey(key);
      final hasSuccessor = queueState.successorByEntityKey.containsKey(key);
      final existingOverlay = state.overlayByEntityKey[key];
      final retainedOp = queueState.successorByEntityKey[key]?.pending.op ??
          queueState.inFlightByEntityKey[key]?.pending.op ??
          queueState.queuedByEntityKey[key]?.pending.op;

      final shouldPreserveTouched = hasQueued || hasInFlight || hasSuccessor;
      final matchesRemote = _entitiesEquivalent(local, remote);
      final matchesHydratedBase = _entitiesEquivalent(local, hydratedBase);
      // A restored queue entry has no in-memory overlay. If the canvas still
      // matches its hydrated base, the durable op is the only local intent and
      // must remain desired until it lands or the user changes that entity,
      // whether it is queued or already sent: the version on screen is older
      // than it, not a change to send after it.
      if (existingOverlay == null &&
          retainedOp != null &&
          matchesHydratedBase) {
        retainedDesiredOps[key] = retainedOp;
        _debugLog('overlay.keep $key reason=durable_queue_only');
        continue;
      }

      // The user deleted, on the canvas, an item whose change the server
      // refused because a teammate deleted it: both sides have it deleted,
      // so the refused change has nothing left to keep, and Keep mine must
      // not bring the item back.
      if (local == null &&
          existingOverlay != null &&
          (remote == null || remote.deleted) &&
          queueState.attentionByEntityKey.containsKey(key) &&
          ref.read(strategyOpQueueProvider.notifier).refusedAsDeleted(key)) {
        settledAttention.add(key);
      }

      if (matchesHydratedBase && !shouldPreserveTouched) {
        if (nextOverlay.remove(key) != null) {
          _debugLog('overlay.remove $key reason=unchanged_since_hydration');
        }
        continue;
      }

      if (matchesRemote && !shouldPreserveTouched) {
        if (nextOverlay.remove(key) != null) {
          _debugLog('overlay.remove $key reason=matched_remote');
        }
        continue;
      }

      if (local == null && remote == null && !shouldPreserveTouched) {
        if (nextOverlay.remove(key) != null) {
          _debugLog('overlay.remove $key reason=missing_local_and_remote');
        }
        continue;
      }

      if (matchesRemote && shouldPreserveTouched && local != null) {
        final overlay = _overlayFromDesiredEntity(
          key: key,
          desired: local,
          hydratedBase: hydratedBase,
          existingOverlay: existingOverlay,
        );
        nextOverlay[key] = overlay;
        _debugLog('overlay.keep $key reason=pending_reconciliation');
        continue;
      }

      if (matchesRemote && existingOverlay != null && !shouldPreserveTouched) {
        nextOverlay.remove(key);
        _debugLog('overlay.remove $key reason=stale_overlay_cleared');
        continue;
      }

      if (local == null) {
        if (hydratedBase == null &&
            existingOverlay == null &&
            !shouldPreserveTouched) {
          _debugLog(
            'overlay.skip $key reason=not_in_hydrated_base',
          );
          continue;
        }
        final entityType = existingOverlay?.entityType ??
            hydratedBase?.overlayEntityType ??
            remote?.overlayEntityType ??
            key.overlayType;
        if (entityType == null) {
          _debugLog('overlay.skip $key reason=unsupported_entity_key');
          continue;
        }
        final overlay = ActivePageOverlayEntry(
          entityKey: key,
          entityType: entityType,
          desiredPayload: null,
          desiredSortIndex: null,
          deletion: true,
          baseRevision: existingOverlay?.baseRevision ?? hydratedBase?.revision,
          baseDeleted:
              existingOverlay?.baseDeleted ?? hydratedBase?.deleted ?? false,
          dirtyAt: DateTime.now(),
        );
        nextOverlay[key] = overlay;
        _debugLog('overlay.upsert $key deletion=true');
        continue;
      }

      final overlay = _overlayFromDesiredEntity(
        key: key,
        desired: local,
        hydratedBase: hydratedBase,
        existingOverlay: existingOverlay,
      );
      nextOverlay[key] = overlay;
      _debugLog(
        'overlay.upsert $key deletion=false baseRevision=${overlay.baseRevision}',
      );
    }

    if (settledAttention.isNotEmpty) {
      // A refusal still waiting to be announced is moot too, as when the
      // user chooses Use cloud.
      for (final key in settledAttention) {
        final refused = queueState.attentionByEntityKey[key]!.pending.op.opId;
        ref.read(strategyConflictProvider.notifier).clear(refused);
      }
      unawaited(
        ref
            .read(strategyOpQueueProvider.notifier)
            .settleAttention(settledAttention),
      );
    }

    final desiredOpsByEntityKey = <EntitySyncKey, StrategyOp>{
      ...retainedDesiredOps,
    };
    for (final entry in nextOverlay.entries) {
      final key = entry.key;
      if (key.pageId != pageId) {
        continue;
      }
      final remote = remoteEntities[key];
      final overlay = entry.value;
      if (_overlayMatchesRemote(overlay, remote) &&
          !_needsSuccessor(
            pageId: pageId,
            key: key,
            overlay: overlay,
            queueState: queueState,
          )) {
        continue;
      }
      final op = _strategyOpFromOverlay(pageId: pageId, overlay: overlay);
      if (op != null) {
        desiredOpsByEntityKey[key] = op;
      }
    }

    state = state.copyWith(
      strategyPublicId: strategyPublicId,
      activePageId: pageId,
      overlayByEntityKey: nextOverlay,
    );

    return desiredOpsByEntityKey;
  }

  ActivePageProjectedState? projectPageState({
    required String strategyPublicId,
    required String pageId,
    Set<EntitySyncKey> excludedOverlays = const {},
  }) {
    setContext(strategyPublicId: strategyPublicId, activePageId: pageId);
    final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
    if (snapshot == null ||
        snapshot.header.publicId != strategyPublicId ||
        snapshot.activePage?.page.publicId != pageId) {
      return null;
    }

    final page = _remotePageById(snapshot: snapshot, pageId: pageId);
    if (page == null) {
      return null;
    }

    final remoteElements = {
      for (final element in (snapshot.elementsByPage[page.publicId] ??
          const <RemoteElement>[]))
        if (!element.deleted)
          EntitySyncKey.element(page.publicId, element.publicId):
              ProjectedPageElement(
            publicId: element.publicId,
            elementType: element.elementType,
            payload: element.payload,
            sortIndex: element.sortIndex,
          ),
    };
    final remoteLineups = {
      for (final lineup
          in (snapshot.lineupsByPage[page.publicId] ?? const <RemoteLineup>[]))
        if (!lineup.deleted)
          EntitySyncKey.lineup(page.publicId, lineup.publicId):
              ProjectedPageLineup(
            publicId: lineup.publicId,
            payload: lineup.payload,
            sortIndex: lineup.sortIndex,
          ),
    };

    var projectedSettingsPayload = snapshot.activePage?.content.settings;
    var projectedIsAttack = page.isAttack;

    final pageOverlays = state.overlayByEntityKey.entries.where(
      (entry) =>
          entry.key.pageId == page.publicId &&
          !excludedOverlays.contains(entry.key),
    );
    for (final entry in pageOverlays) {
      final overlay = entry.value;
      switch (overlay.entityType) {
        case ActivePageOverlayEntityType.pageDescriptor:
          if (overlay.desiredPayload == null) {
            continue;
          }
          final decoded = _decodeObject(overlay.desiredPayload!);
          final isAttack = decoded['isAttack'];
          if (isAttack is bool) {
            projectedIsAttack = isAttack;
          }
          continue;
        case ActivePageOverlayEntityType.pageContent:
          if (overlay.desiredPayload != null) {
            final decoded = _decodeObject(overlay.desiredPayload!);
            projectedSettingsPayload =
                cloudObjectPayloadOrNull(decoded['settings']);
          }
          continue;
        case ActivePageOverlayEntityType.element:
          if (overlay.deletion) {
            remoteElements.remove(entry.key);
            continue;
          }
          final elementId = entry.key.entityId;
          if (elementId == null || overlay.desiredPayload == null) {
            continue;
          }
          final decoded = cloudPayloadData(overlay.desiredPayload);
          final elementType = decoded['elementType'] as String? ??
              (overlay.desiredPayload as Map?)?['kind'] as String?;
          if (elementType == null) {
            _debugLog(
              'projected.skip_overlay ${entry.key} reason=missing_element_type',
            );
            continue;
          }
          remoteElements[entry.key] = ProjectedPageElement(
            publicId: elementId,
            elementType: elementType,
            payload: Map<String, dynamic>.from(overlay.desiredPayload! as Map),
            sortIndex: overlay.desiredSortIndex ?? 0,
          );
          continue;
        case ActivePageOverlayEntityType.lineup:
          if (overlay.deletion) {
            remoteLineups.remove(entry.key);
            continue;
          }
          final lineupId = entry.key.entityId;
          if (lineupId == null || overlay.desiredPayload == null) {
            continue;
          }
          remoteLineups[entry.key] = ProjectedPageLineup(
            publicId: lineupId,
            payload: Map<String, dynamic>.from(overlay.desiredPayload! as Map),
            sortIndex: overlay.desiredSortIndex ?? 0,
          );
          continue;
      }
    }

    _debugLog(
      'projected.rehydrate page=${page.publicId} overlays=${pageOverlays.length}',
    );

    return ActivePageProjectedState(
      pageId: page.publicId,
      pageName: page.name,
      isAttack: projectedIsAttack,
      settingsPayload: projectedSettingsPayload,
      elements: remoteElements.values.toList(growable: false)
        ..sortBySortIndex((item) => item.sortIndex),
      lineups: remoteLineups.values.toList(growable: false)
        ..sortBySortIndex((item) => item.sortIndex),
    );
  }

  Map<String, dynamic> _decodeObject(Object payload) {
    final decoded = payload is String ? jsonDecode(payload) : payload;
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    return const <String, dynamic>{};
  }

  Map<EntitySyncKey, _NormalizedEntity> _normalizedRemoteEntities(
    RemoteEditorSnapshot snapshot,
    String pageId,
  ) {
    final page = _remotePageById(snapshot: snapshot, pageId: pageId);
    if (page == null) {
      return const <EntitySyncKey, _NormalizedEntity>{};
    }

    final pageSnapshot = snapshot.activePage;
    if (pageSnapshot == null || pageSnapshot.page.publicId != page.publicId) {
      return const <EntitySyncKey, _NormalizedEntity>{};
    }

    final entities = <EntitySyncKey, _NormalizedEntity>{
      EntitySyncKey.pageDescriptor(page.publicId): _NormalizedEntity(
        key: EntitySyncKey.pageDescriptor(page.publicId),
        overlayEntityType: ActivePageOverlayEntityType.pageDescriptor,
        payload: <String, dynamic>{'isAttack': page.isAttack},
        sortIndex: null,
        revision: page.revision,
        deleted: false,
      ),
      EntitySyncKey.pageContent(page.publicId): _NormalizedEntity(
        key: EntitySyncKey.pageContent(page.publicId),
        overlayEntityType: ActivePageOverlayEntityType.pageContent,
        payload: <String, dynamic>{
          'settings': pageSnapshot.content.settings,
        },
        sortIndex: null,
        revision: pageSnapshot.content.revision,
        deleted: false,
      ),
    };

    for (final element in (snapshot.elementsByPage[page.publicId] ??
        const <RemoteElement>[])) {
      final key = EntitySyncKey.element(page.publicId, element.publicId);
      entities[key] = _NormalizedEntity(
        key: key,
        overlayEntityType: ActivePageOverlayEntityType.element,
        payload: element.payload,
        sortIndex: element.sortIndex,
        revision: element.revision,
        deleted: element.deleted,
      );
    }

    for (final lineup
        in (snapshot.lineupsByPage[page.publicId] ?? const <RemoteLineup>[])) {
      final key = EntitySyncKey.lineup(page.publicId, lineup.publicId);
      entities[key] = _NormalizedEntity(
        key: key,
        overlayEntityType: ActivePageOverlayEntityType.lineup,
        payload: lineup.payload,
        sortIndex: lineup.sortIndex,
        revision: lineup.revision,
        deleted: lineup.deleted,
      );
    }

    return entities;
  }

  Map<EntitySyncKey, _NormalizedEntity> _normalizedLocalEntities(
      String pageId) {
    final entities = <EntitySyncKey, _NormalizedEntity>{};

    final descriptorKey = EntitySyncKey.pageDescriptor(pageId);
    entities[descriptorKey] = _NormalizedEntity(
      key: descriptorKey,
      overlayEntityType: ActivePageOverlayEntityType.pageDescriptor,
      payload: <String, dynamic>{
        'isAttack': ref.read(mapProvider).isAttack,
      },
      sortIndex: null,
      revision: 0,
      deleted: false,
    );
    final contentKey = EntitySyncKey.pageContent(pageId);
    entities[contentKey] = _NormalizedEntity(
      key: contentKey,
      overlayEntityType: ActivePageOverlayEntityType.pageContent,
      payload: <String, dynamic>{
        'settings': ref.read(strategySettingsProvider).toJson(),
      },
      sortIndex: null,
      revision: 0,
      deleted: false,
    );

    // A row keeps the sortIndex it was first sent with and new rows go after
    // the page's highest. Removing an element or lineup (here or by a
    // teammate) then rewrites no row after it, which would collide with a
    // teammate editing one of them; the server never renumbers either.
    int? knownSortIndex(EntitySyncKey key) =>
        state.overlayByEntityKey[key]?.desiredSortIndex ??
        _hydratedBaseByEntityKey[key]?.sortIndex;

    /// Hands out sortIndexes after the page's highest for [kind].
    int Function() freshSortIndexes(EntitySyncKeyKind kind) {
      bool onPage(EntitySyncKey key) =>
          key.pageId == pageId && key.kind == kind;
      var next = 1 +
          [
            for (final key in _hydratedBaseByEntityKey.keys)
              if (onPage(key)) knownSortIndex(key) ?? 0,
            for (final key in state.overlayByEntityKey.keys)
              if (onPage(key)) knownSortIndex(key) ?? 0,
          ].fold<int>(-1, max);
      return () => next++;
    }

    // Elements stack in list order within each kind (each kind is its own
    // canvas layer), and moving or restoring one brings it to the front of its
    // list. A known sortIndex is kept while it still sorts after the one
    // before it in the same list (a tie only while the two are still in the
    // order hydration drew them); an element that moved ahead goes after the
    // page's highest.
    final freshElementSortIndex = freshSortIndexes(EntitySyncKeyKind.element);
    final previousByKind = <_CollabElementKind, (EntitySyncKey, int)>{};
    bool drawnInThisOrder(EntitySyncKey first, EntitySyncKey second) {
      final a = _hydratedPositionByKey[first];
      final b = _hydratedPositionByKey[second];
      return a != null && b != null && a < b;
    }

    int stackedSortIndex(EntitySyncKey key, _CollabElementKind kind) {
      final known = knownSortIndex(key);
      if (_heldDeletedKeys.contains(key) && known != null) return known;
      final previous = previousByKind[kind];
      final keep = known != null &&
          (previous == null ||
              known > previous.$2 ||
              (known == previous.$2 && drawnInThisOrder(previous.$1, key)));
      final sortIndex = keep ? known : freshElementSortIndex();
      previousByKind[kind] = (key, sortIndex);
      return sortIndex;
    }

    for (final envelope in _collectLocalElementEnvelopes()) {
      final key = EntitySyncKey.element(pageId, envelope.publicId);
      entities[key] = _NormalizedEntity(
        key: key,
        overlayEntityType: ActivePageOverlayEntityType.element,
        payload: cloudElementPayload(
            kind: envelope.kind.name, data: envelope.payload),
        sortIndex: stackedSortIndex(key, envelope.kind),
        revision: 0,
        deleted: false,
      );
    }

    // One row per lineup group, holding its lineups and their spots as the
    // canvas draws them. A group nobody changed matches its stored row, so
    // it is never written. A new group never takes the id of a row this page
    // has or had, so it never lands on a teammate's group or a deleted one.
    final freshLineupSortIndex = freshSortIndexes(EntitySyncKeyKind.lineup);
    final lineupGroupOf = _lineupGroupOfByPage[pageId] ??= {};
    final lineupRows = cloudLineupRows(
      ref.read(lineUpProvider).graph,
      groupOf: lineupGroupOf,
      takenGroupIds: {
        for (final key in [
          ..._hydratedBaseByEntityKey.keys,
          ...state.overlayByEntityKey.keys,
        ])
          if (key.pageId == pageId && key.kind == EntitySyncKeyKind.lineup)
            key.entityId!,
      },
    );
    _rememberLineupGroups(lineupGroupOf, lineupRows.groupOf);
    for (final row in lineupRows.rows) {
      final key = EntitySyncKey.lineup(pageId, row.publicId);
      entities[key] = _NormalizedEntity(
        key: key,
        overlayEntityType: ActivePageOverlayEntityType.lineup,
        payload: row.payload,
        sortIndex: knownSortIndex(key) ?? freshLineupSortIndex(),
        revision: 0,
        deleted: false,
      );
    }
    return entities;
  }

  List<_CollabElementEnvelope> _collectLocalElementEnvelopes() {
    final envelopes = <_CollabElementEnvelope>[];

    for (final agent in ref.read(agentProvider)) {
      final payload = Map<String, dynamic>.from(agent.toJson())
        ..putIfAbsent('elementType', () => _CollabElementKind.agent.name);
      envelopes.add(
        _CollabElementEnvelope(
          publicId: agent.id,
          kind: _CollabElementKind.agent,
          payload: payload,
        ),
      );
    }

    for (final ability in ref.read(abilityProvider)) {
      final payload = Map<String, dynamic>.from(ability.toJson())
        ..putIfAbsent('elementType', () => _CollabElementKind.ability.name);
      envelopes.add(
        _CollabElementEnvelope(
          publicId: ability.id,
          kind: _CollabElementKind.ability,
          payload: payload,
        ),
      );
    }

    for (final drawing in ref.read(drawingProvider).elements) {
      final encoded =
          jsonDecode(DrawingProvider.objectToJson([drawing])) as List;
      final payload = Map<String, dynamic>.from(
        (encoded.isEmpty ? <String, dynamic>{} : encoded.first) as Map,
      )..putIfAbsent('elementType', () => _CollabElementKind.drawing.name);
      envelopes.add(
        _CollabElementEnvelope(
          publicId: drawing.id,
          kind: _CollabElementKind.drawing,
          payload: payload,
        ),
      );
    }

    for (final text
        in ref.read(textProvider.notifier).snapshotForPersistence()) {
      final payload = Map<String, dynamic>.from(text.toJson())
        ..putIfAbsent('elementType', () => _CollabElementKind.text.name);
      envelopes.add(
        _CollabElementEnvelope(
          publicId: text.id,
          kind: _CollabElementKind.text,
          payload: payload,
        ),
      );
    }

    for (final image in ref.read(placedImageProvider).images) {
      final payload = Map<String, dynamic>.from(
        cloudImagePayloadFromPlacedImage(image),
      )..putIfAbsent('elementType', () => _CollabElementKind.image.name);
      envelopes.add(
        _CollabElementEnvelope(
          publicId: image.id,
          kind: _CollabElementKind.image,
          payload: payload,
        ),
      );
    }

    for (final utility in ref.read(utilityProvider)) {
      final payload = Map<String, dynamic>.from(utility.toJson())
        ..putIfAbsent('elementType', () => _CollabElementKind.utility.name);
      envelopes.add(
        _CollabElementEnvelope(
          publicId: utility.id,
          kind: _CollabElementKind.utility,
          payload: payload,
        ),
      );
    }

    return envelopes;
  }

  ActivePageOverlayEntry _overlayFromDesiredEntity({
    required EntitySyncKey key,
    required _NormalizedEntity desired,
    required _NormalizedEntity? hydratedBase,
    required ActivePageOverlayEntry? existingOverlay,
  }) {
    return ActivePageOverlayEntry(
      entityKey: key,
      entityType: desired.overlayEntityType,
      desiredPayload: desired.payload,
      desiredSortIndex: desired.sortIndex,
      deletion: desired.deleted,
      baseRevision: existingOverlay?.baseRevision ?? hydratedBase?.revision,
      baseDeleted:
          existingOverlay?.baseDeleted ?? hydratedBase?.deleted ?? false,
      dirtyAt: DateTime.now(),
    );
  }

  StrategyOp? _strategyOpFromOverlay({
    required String pageId,
    required ActivePageOverlayEntry overlay,
  }) {
    final entityId = overlay.entityKey.entityId;
    switch (overlay.entityType) {
      case ActivePageOverlayEntityType.pageDescriptor:
        final baseRevision = overlay.baseRevision;
        if (baseRevision == null) return null;
        return PagePatchOp(
          opId: const Uuid().v4(),
          pagePublicId: pageId,
          payload: Map<String, dynamic>.from(overlay.desiredPayload as Map),
          expectedPageRevision: baseRevision,
        );
      case ActivePageOverlayEntityType.pageContent:
        final baseRevision = overlay.baseRevision;
        if (baseRevision == null) return null;
        final payload = Map<String, dynamic>.from(
          overlay.desiredPayload as Map,
        );
        return PageContentPatchOp(
          opId: const Uuid().v4(),
          pagePublicId: pageId,
          settings: Map<String, dynamic>.from(payload['settings'] as Map),
          expectedPageContentRevision: baseRevision,
        );
      case ActivePageOverlayEntityType.element:
        if (entityId == null) {
          return null;
        }
        if (overlay.deletion) {
          // A delete after a local add has no revision until that add lands.
          // Zero cannot land early; the outbox rebases the successor from the
          // accepted add acknowledgment.
          final baseRevision = overlay.baseRevision ?? 0;
          return ElementDeleteOp(
            opId: const Uuid().v4(),
            elementPublicId: entityId,
            pagePublicId: pageId,
            expectedElementRevision: baseRevision,
          );
        }
        final payload =
            Map<String, dynamic>.from(overlay.desiredPayload as Map);
        return overlay.baseRevision == null || overlay.baseDeleted
            ? ElementAddOp(
                opId: const Uuid().v4(),
                elementPublicId: entityId,
                pagePublicId: pageId,
                payload: payload,
                sortIndex: overlay.desiredSortIndex ?? 0,
                expectedElementRevision: overlay.baseRevision,
              )
            : _patchOp(
                overlay,
                payload,
                lineup: false,
                build: (merge, sortIndex) => ElementPatchOp(
                  opId: const Uuid().v4(),
                  elementPublicId: entityId,
                  pagePublicId: pageId,
                  payload: payload,
                  sortIndex: sortIndex,
                  expectedElementRevision: overlay.baseRevision!,
                  merge: merge,
                ),
              );
      case ActivePageOverlayEntityType.lineup:
        if (entityId == null) {
          return null;
        }
        if (overlay.deletion) {
          final baseRevision = overlay.baseRevision ?? 0;
          return LineupDeleteOp(
            opId: const Uuid().v4(),
            lineupPublicId: entityId,
            pagePublicId: pageId,
            expectedLineupRevision: baseRevision,
          );
        }
        final payload =
            Map<String, dynamic>.from(overlay.desiredPayload as Map);
        return overlay.baseRevision == null || overlay.baseDeleted
            ? LineupAddOp(
                opId: const Uuid().v4(),
                lineupPublicId: entityId,
                pagePublicId: pageId,
                payload: payload,
                sortIndex: overlay.desiredSortIndex ?? 0,
                expectedLineupRevision: overlay.baseRevision,
              )
            : _patchOp(
                overlay,
                payload,
                lineup: true,
                build: (merge, sortIndex) => LineupPatchOp(
                  opId: const Uuid().v4(),
                  lineupPublicId: entityId,
                  pagePublicId: pageId,
                  payload: payload,
                  sortIndex: sortIndex,
                  expectedLineupRevision: overlay.baseRevision!,
                  merge: merge,
                ),
              );
    }
  }

  /// A patch of [overlay]'s element or lineup group, merged by field when
  /// it can be (see FieldMerge): naming what [payload] changes from the
  /// version this canvas was drawn from, with those fields' values there as
  /// its base, and its place only if that moved too, so it writes over none
  /// of a teammate's changes to the rest. Otherwise a whole, revision-checked
  /// write of the item and its place. Either way it carries the place the
  /// user has, which Keep mine needs to restore a deleted item.
  StrategyOp _patchOp(
    ActivePageOverlayEntry overlay,
    Object payload, {
    required bool lineup,
    required StrategyOp Function(FieldMerge? merge, int? sortIndex) build,
  }) {
    final base = _hydratedBaseByEntityKey[overlay.entityKey];
    final fields =
        base == null || base.deleted || base.revision != overlay.baseRevision
            ? null
            : lineup
                ? lineupMergeFields(base.payload, payload,
                    normalize: _withFieldDefaults)
                : elementMergeFields(base.payload, payload,
                    normalize: _withFieldDefaults);
    if (base == null || fields == null) {
      return build(null, overlay.desiredSortIndex);
    }
    final moved = overlay.desiredSortIndex != null &&
        overlay.desiredSortIndex != base.sortIndex;
    return build(
      FieldMerge(
        fields: [...fields, if (moved) placeMergeField],
        base: {
          ...mergeBaseValues(base.payload, fields, lineup: lineup),
          if (moved && base.sortIndex != null) placeMergeField: base.sortIndex,
        },
      ),
      overlay.desiredSortIndex,
    );
  }

  bool _overlayMatchesRemote(
    ActivePageOverlayEntry overlay,
    _NormalizedEntity? remote,
  ) {
    if (overlay.deletion) {
      return remote == null || remote.deleted;
    }
    if (remote == null || remote.deleted) {
      return false;
    }
    return _payloadsEquivalent(overlay.desiredPayload, remote.payload) &&
        overlay.desiredSortIndex == remote.sortIndex;
  }

  bool _needsSuccessor({
    required String pageId,
    required EntitySyncKey key,
    required ActivePageOverlayEntry overlay,
    required StrategyOpQueueState queueState,
  }) {
    if (queueState.successorByEntityKey.containsKey(key)) {
      return false;
    }

    final predecessor = queueState.inFlightByEntityKey[key]?.pending.op ??
        queueState.queuedByEntityKey[key]?.pending.op;
    if (predecessor == null) return false;
    final desired = _strategyOpFromOverlay(pageId: pageId, overlay: overlay);
    return desired != null && !_opsEquivalent(predecessor, desired);
  }

  bool _opsEquivalent(StrategyOp left, StrategyOp right) {
    return left.kind == right.kind &&
        left.entityType == right.entityType &&
        left.entityPublicId == right.entityPublicId &&
        left.pagePublicId == right.pagePublicId &&
        cloudJsonEquivalent(left.payload, right.payload) &&
        left.sortIndex == right.sortIndex &&
        left.expectedRevision == right.expectedRevision;
  }

  bool _entitiesEquivalent(
    _NormalizedEntity? local,
    _NormalizedEntity? remote,
  ) {
    if (identical(local, remote)) {
      return true;
    }
    if (local == null) {
      return remote?.deleted ?? false;
    }
    if (remote == null) {
      return false;
    }
    return local.deleted == remote.deleted &&
        _payloadsEquivalent(local.payload, remote.payload) &&
        local.sortIndex == remote.sortIndex &&
        local.overlayEntityType == remote.overlayEntityType;
  }

  bool _payloadsEquivalent(Object? left, Object? right) {
    return cloudJsonEquivalent(
      _withFieldDefaults(left),
      _withFieldDefaults(right),
    );
  }

  /// Payloads written before a field existed compare equal to the field's
  /// default, so hydrating old cloud data never authors a rewrite of it.
  Object? _withFieldDefaults(Object? value) {
    if (value is List) {
      return [for (final item in value) _withFieldDefaults(item)];
    }
    if (value is! Map) {
      return value;
    }
    final normalized = <String, dynamic>{
      for (final entry in value.entries)
        entry.key.toString(): _withFieldDefaults(entry.value),
    };
    final visualState = normalized['visualState'];
    if (visualState is Map<String, dynamic>) {
      visualState.putIfAbsent('showVisionCone', () => true);
    }
    // Only agents carry an AgentState; firearms default to none.
    if (normalized.containsKey('state')) {
      normalized.putIfAbsent('weapon', () => WeaponType.none.name);
    }
    return normalized;
  }

  void _debugLog(String message) {
    assert(() {
      log(message, name: 'active_page_live_sync');
      return true;
    }());
  }

  RemotePage? _remotePageById({
    required RemoteEditorSnapshot snapshot,
    required String pageId,
  }) {
    for (final page in snapshot.pages) {
      if (page.publicId == pageId) {
        return page;
      }
    }
    return null;
  }
}

class _NormalizedEntity {
  const _NormalizedEntity({
    required this.key,
    required this.overlayEntityType,
    required this.payload,
    required this.sortIndex,
    required this.revision,
    required this.deleted,
  });

  final EntitySyncKey key;
  final ActivePageOverlayEntityType overlayEntityType;
  final Object payload;
  final int? sortIndex;
  final int revision;
  final bool deleted;
}

class _CollabElementEnvelope {
  const _CollabElementEnvelope({
    required this.publicId,
    required this.kind,
    required this.payload,
  });

  final String publicId;
  final _CollabElementKind kind;
  final Map<String, dynamic> payload;
}

enum _CollabElementKind {
  agent,
  ability,
  drawing,
  text,
  image,
  utility;
}
