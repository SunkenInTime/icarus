import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:math' show max, min;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/collab/cloud_payload_upgrade.dart';
import 'package:icarus/const/sort_index_order.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/field_merge.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
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
import 'package:icarus/strategy/cloud_element_decoding.dart';
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

  /// Work recovered from the outbox that the canvas drew on top of the
  /// server's version, by entity: work queued before the canvas was drawn
  /// (after a restart, or a trip to another strategy). See [_drawQueuedWork].
  final Map<EntitySyncKey, _DrawnWork> _drawnWorkByKey = {};

  /// What the page's last projection drew from the outbox, over the page
  /// answer [page]: taken as drawn when the canvas is hydrated from it.
  ({
    String pageId,
    RemotePageSnapshot? page,
    Map<EntitySyncKey, _DrawnWork> work,
  })? _projectedWork;

  /// Per page, whether the canvas was drawn from a live server answer
  /// received on the connection that is up now (see
  /// RemoteEditorSnapshotNotifier.answeredOnCurrentConnection): the
  /// connection's stamp then, or null.
  final Map<String, int?> _pageAnsweredOn = {};

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
    _drawnWorkByKey.clear();
    _projectedWork = null;
    _pageAnsweredOn.clear();
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
    final answeredOn = matchesPage &&
            ref
                .read(remoteEditorSnapshotProvider.notifier)
                .answeredOnCurrentConnection(snapshot.activePage)
        ? ref.read(strategyOpQueueProvider.notifier).liveStamp
        : null;
    _pageAnsweredOn[pageId] = answeredOn;
    final remoteEntities = {
      if (matchesPage)
        ..._normalizedRemoteEntities(snapshot, pageId, receivedOn: answeredOn),
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
      remoteEntities[key] = drawnBase.copyWith(
        sortIndex: serverSortIndex ?? drawnBase.sortIndex,
      );
    }
    // A base never goes back to an older revision: a page read before this
    // client's own edit landed must not undo the base that edit set.
    for (final MapEntry(:key, value: base)
        in _hydratedBaseByEntityKey.entries) {
      if (key.pageId != pageId) continue;
      final remote = remoteEntities[key];
      // An added row the read does not hold yet keeps the base its ack set
      // while its overlay waits for it.
      final waitingAdd = remote == null &&
          !base.deleted &&
          state.overlayByEntityKey.containsKey(key);
      if (waitingAdd || (remote != null && remote.revision < base.revision)) {
        remoteEntities[key] = base;
      }
    }
    _takeProjectedWork(pageId, snapshot, keepBaseFor: keepBaseFor);
    // Work drawn from the outbox is checked against what it was made
    // against, not the server's version it was drawn over.
    for (final MapEntry(:key, value: drawn) in _drawnWorkByKey.entries) {
      if (key.pageId != pageId || keepBaseFor.contains(key)) continue;
      final base = drawn.base;
      if (base == null) {
        remoteEntities.remove(key);
      } else {
        remoteEntities[key] = base.copyWith(receivedOn: answeredOn);
      }
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

  /// Takes what the last projection of [pageId] drew from the outbox as
  /// what the canvas shows, if it was drawn over [snapshot]'s page: the
  /// canvas is being hydrated from it. Entities in [keepBaseFor] (held, so
  /// not taken from it) keep what they were drawn with.
  void _takeProjectedWork(
    String pageId,
    RemoteEditorSnapshot snapshot, {
    required Set<EntitySyncKey> keepBaseFor,
  }) {
    final projected = _projectedWork;
    if (projected == null ||
        projected.pageId != pageId ||
        !identical(projected.page, snapshot.activePage)) {
      return;
    }
    _projectedWork = null;
    _drawnWorkByKey.removeWhere(
      (key, _) => key.pageId == pageId && !keepBaseFor.contains(key),
    );
    for (final MapEntry(:key, :value) in projected.work.entries) {
      if (!keepBaseFor.contains(key)) _drawnWorkByKey[key] = value;
    }
    ref.read(strategyOpQueueProvider.notifier).noteDrawnWork([
      for (final MapEntry(:key, :value) in _drawnWorkByKey.entries)
        if (key.pageId == pageId)
          for (final layer in value.layers) layer.opId,
    ]);
  }

  /// The stamp to queue work made on [pageId] now with (see
  /// StrategyOpQueueNotifier.liveStamp): null, so it is sent checked, unless
  /// the connection is up and everything on the page was drawn from a live
  /// server answer received on it. A page drawn from this computer's copy,
  /// or before the connection last came back, keeps its conflict checks
  /// until a fresh answer for it is drawn.
  int? liveStampForEdits(String pageId) {
    final stamp = ref.read(strategyOpQueueProvider.notifier).liveStamp;
    if (stamp == null ||
        state.hydratedPageId != pageId ||
        _pageAnsweredOn[pageId] != stamp) {
      return null;
    }
    for (final MapEntry(:key, value: base)
        in _hydratedBaseByEntityKey.entries) {
      if (key.pageId == pageId && base.receivedOn != stamp) return null;
    }
    return stamp;
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
    // What the projection of this page draws from the outbox now, against
    // what the canvas drew from it.
    final projected = _projectedWork;
    final projectedWork = projected != null &&
            projected.pageId == pageId &&
            identical(projected.page, snapshot.activePage)
        ? projected.work
        : null;
    final keys = {
      ...remote.keys,
      ..._hydratedBaseByEntityKey.keys.where((key) => key.pageId == pageId),
      ..._drawnWorkByKey.keys.where((key) => key.pageId == pageId),
      ...?projectedWork?.keys,
    };
    // An entity drawn with outbox work was drawn over the server's version
    // it then had.
    _NormalizedEntity? drawnFrom(EntitySyncKey key) =>
        _drawnWorkByKey.containsKey(key)
            ? _drawnWorkByKey[key]!.over
            : _hydratedBaseByEntityKey[key];
    return {
      for (final key in keys)
        if (!_sameLiveEntity(live(remote[key]), live(drawnFrom(key))) ||
            (projectedWork != null &&
                !_sameLiveEntity(
                  live(projectedWork[key]?.drawn),
                  live(_drawnWorkByKey[key]?.drawn),
                )))
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
      // An added row the page read does not hold yet waits for it, as an
      // edit waits for its revision.
      if (row == null) return overlay.deletion || landedAt == 0;
      return row.revision >= landedAt;
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
    // An ack is a live answer, received on the connection up now.
    final receivedOn = ref.read(strategyOpQueueProvider.notifier).liveStamp;
    for (final intent in intents) {
      final revision = intent.ack.appliedRevision;
      final key = intent.entityKey;
      if (revision == null) {
        continue;
      }
      final drawnLayer = _landDrawnWork(
        key,
        intent.op,
        untouched: !overlays.containsKey(key),
        revision: revision,
      );
      final normalized = drawnLayer?.copyWith(
            revision: revision,
            receivedOn: receivedOn,
          ) ??
          _normalizedAcceptedEntity(
            key: key,
            op: intent.op,
            revision: revision,
          )?.copyWith(receivedOn: receivedOn);
      if (normalized == null) continue;
      // A merge landed onto whatever the row held, which this client may
      // not have drawn: a whole write still claims only the revision before.
      final accepted = intent.op.merge == null
          ? normalized
          : normalized.withClaimableRevision(
              _hydratedBaseByEntityKey[key]?.claimableRevision ?? revision - 1,
            );
      if (_drawnWorkByKey[key] case final landed?
          when landed.landedAt == revision) {
        _drawnWorkByKey[key] = _DrawnWork(
          over: landed.over,
          layers: landed.layers,
          base: accepted,
          landedAt: revision,
        );
      }

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
      // conflicts instead of replacing the recovered work. Work it drew
      // from the outbox is on screen, and is no such change.
      if (intent.restored && drawnLayer == null) continue;
      _hydratedBaseByEntityKey[key] = accepted;
      remoteRevisions[key] = revision;
    }
    state = state.copyWith(
      overlayByEntityKey: overlays,
      remoteBaseRevisionByEntity: remoteRevisions,
      lastAckBatch: intents,
    );
  }

  /// What the canvas drew [key] as once [op], outbox work it drew, lands:
  /// the server now holds that for it, and the work queued behind [op], if
  /// any, stays drawn over it. Null when [op] is not work the canvas drew.
  /// An op the queue sends in place of drawn work ([untouched], the user has
  /// not edited it since: a newer change promoted behind the one that
  /// landed, a retry) lands what was drawn last.
  _NormalizedEntity? _landDrawnWork(
    EntitySyncKey key,
    StrategyOp op, {
    required bool untouched,
    required int revision,
  }) {
    final drawn = _drawnWorkByKey[key];
    if (drawn == null) return null;
    var index = drawn.layers.indexWhere((layer) => layer.opId == op.opId);
    if (index < 0) {
      if (!untouched) {
        // The canvas's own edit replaced the drawn work.
        _drawnWorkByKey.remove(key);
        return null;
      }
      index = drawn.layers.length - 1;
    }
    final landed = drawn.layers[index].entity;
    final rest = drawn.layers.sublist(index + 1);
    if (rest.isEmpty && !untouched) {
      // The canvas's own edit since is in its overlay, which keeps it drawn
      // until the server's read shows it.
      _drawnWorkByKey.remove(key);
    } else if (rest.isEmpty) {
      // Its base is set once the ack's is (see recordAckBatch).
      _drawnWorkByKey[key] = _DrawnWork(
        over: landed,
        layers: [(opId: op.opId, entity: landed)],
        base: null,
        landedAt: revision,
      );
    } else {
      _drawnWorkByKey[key] =
          _DrawnWork(over: landed, layers: rest, base: drawn.base);
    }
    return landed;
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
      _drawnWorkByKey.remove(key);
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
      ..._drawnWorkByKey.keys.where((key) => key.pageId == pageId),
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
      final drawn = _drawnWorkByKey[key];
      // The canvas shows the outbox's work for it as drawn: that work, as
      // the queue holds it (sent, paused or refused alike), is the intent.
      if (drawn != null &&
          existingOverlay == null &&
          _entitiesEquivalent(local, drawn.drawn)) {
        final held = retainedOp ??
            queueState.pausedByEntityKey[key]?.pending.op ??
            queueState.attentionByEntityKey[key]?.pending.op;
        if (held != null) retainedDesiredOps[key] = held;
        _debugLog('overlay.keep $key reason=drawn_from_outbox');
        continue;
      }
      // A restored queue entry the canvas never drew has no in-memory
      // overlay. If the canvas still matches its hydrated base, the durable
      // op is the only local intent and must remain desired until it lands
      // or the user changes that entity, whether it is queued or already
      // sent: the version on screen is older than it, not a change to send
      // after it.
      if (drawn == null &&
          existingOverlay == null &&
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

    final drawnWork = _drawQueuedWork(
      snapshot,
      page.publicId,
      excluded: excludedOverlays,
    );
    _projectedWork = (
      pageId: page.publicId,
      page: snapshot.activePage,
      work: drawnWork,
    );
    for (final MapEntry(:key, value: work) in drawnWork.entries) {
      final drawn = work.drawn;
      switch (drawn.overlayEntityType) {
        case ActivePageOverlayEntityType.pageDescriptor:
          final isAttack = _decodeObject(drawn.payload)['isAttack'];
          if (isAttack is bool) projectedIsAttack = isAttack;
        case ActivePageOverlayEntityType.pageContent:
          projectedSettingsPayload = cloudObjectPayloadOrNull(
              _decodeObject(drawn.payload)['settings']);
        case ActivePageOverlayEntityType.element:
          final elementType =
              cloudPayloadData(drawn.payload)['elementType'] as String? ??
                  (drawn.payload as Map?)?['kind'] as String?;
          if (drawn.deleted || elementType == null) {
            remoteElements.remove(key);
          } else {
            remoteElements[key] = ProjectedPageElement(
              publicId: key.entityId!,
              elementType: elementType,
              payload: Map<String, dynamic>.from(drawn.payload as Map),
              sortIndex: drawn.sortIndex ?? 0,
            );
          }
        case ActivePageOverlayEntityType.lineup:
          if (drawn.deleted) {
            remoteLineups.remove(key);
          } else {
            remoteLineups[key] = ProjectedPageLineup(
              publicId: key.entityId!,
              payload: Map<String, dynamic>.from(drawn.payload as Map),
              sortIndex: drawn.sortIndex ?? 0,
            );
          }
      }
    }

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
      'projected.rehydrate page=${page.publicId} '
      'overlays=${pageOverlays.length} outbox=${drawnWork.length}',
    );

    return ActivePageProjectedState(
      pageId: page.publicId,
      pageName: page.name,
      drawsQueuedWork: drawnWork.isNotEmpty,
      isAttack: projectedIsAttack,
      settingsPayload: projectedSettingsPayload,
      elements: remoteElements.values.toList(growable: false)
        ..sortBySortIndex((item) => item.sortIndex),
      lineups: remoteLineups.values.toList(growable: false)
        ..sortBySortIndex((item) => item.sortIndex),
    );
  }

  /// The outbox's work for [pageId] to draw on top of [snapshot]'s version
  /// of it, by entity: what each entity looks like once its waiting work
  /// lands, queued, sent, paused or refused alike, its newer change behind
  /// the one sent included. A patch merged by field draws only the fields it
  /// names, over the server's version as it is now. Work the canvas already
  /// holds as its own (in its overlays, or queued from its edits) is left
  /// to the canvas, as is work the user chose to discard ([excluded]).
  Map<EntitySyncKey, _DrawnWork> _drawQueuedWork(
    RemoteEditorSnapshot snapshot,
    String pageId, {
    required Set<EntitySyncKey> excluded,
  }) {
    final queue = ref.read(strategyOpQueueProvider);
    final queueNotifier = ref.read(strategyOpQueueProvider.notifier);
    final remote = _normalizedRemoteEntities(snapshot, pageId);
    final mapData = snapshot.header.mapData;
    final work = <EntitySyncKey, _DrawnWork>{};
    final noLongerFits =
        <EntitySyncKey, ({String opId, int? serverRevision})>{};
    final keys = {
      for (final intents in [
        queue.queuedByEntityKey,
        queue.inFlightByEntityKey,
        queue.pausedByEntityKey,
        queue.attentionByEntityKey,
      ])
        ...intents.keys.where((key) => key.pageId == pageId),
      for (final MapEntry(:key, :value) in _drawnWorkByKey.entries)
        if (key.pageId == pageId && value.landedAt != null) key,
    };
    for (final key in keys) {
      if (excluded.contains(key) ||
          _remoteAdoptionPending.contains(key) ||
          state.overlayByEntityKey.containsKey(key)) {
        continue;
      }
      final waiting = queue.inFlightByEntityKey[key]?.pending ??
          queue.queuedByEntityKey[key]?.pending ??
          queue.pausedByEntityKey[key]?.pending ??
          queue.attentionByEntityKey[key]?.pending;
      if (waiting == null) {
        // Work drawn here that has landed stays until a read at or past
        // the revision it landed at shows it.
        final landed = _drawnWorkByKey[key]!;
        final row = remote[key];
        final shown = landed.drawn.deleted
            ? row == null || row.revision >= landed.landedAt!
            : row != null && row.revision >= landed.landedAt!;
        if (!shown) work[key] = landed;
        continue;
      }
      final head = waiting.op;
      final ops = [
        head,
        if (queue.successorByEntityKey[key]?.pending.op case final next?) next,
      ];
      if (!_drawnWorkByKey.containsKey(key) &&
          ops.every((op) => queueNotifier.isCanvasWork(op.opId))) {
        continue;
      }
      if (ops.any(isRetiredCloudLineupOp)) continue;
      final over = remote[key];
      _DrawnWork? drawnFrom(Iterable<StrategyOp> ops) {
        var onto = over;
        _NormalizedEntity? base;
        final layers = <({String opId, _NormalizedEntity entity})>[];
        for (final op in ops) {
          final drawn = _drawQueuedOp(key, op, onto, mapData: mapData);
          if (drawn == null) return null;
          layers.add((opId: op.opId, entity: drawn.entity));
          base = drawn.base;
          onto = drawn.entity;
        }
        return _DrawnWork(over: over, layers: layers, base: base);
      }

      final drawn = drawnFrom(ops);
      if (drawn == null) continue;
      if (_drawable(drawn.drawn)) {
        work[key] = drawn;
        continue;
      }
      // Merged field by field onto the server's version it can't be read
      // (a teammate removed what it relies on, say a lineup's landing).
      // Drawing must never leave the page unable to open, nor hide the
      // work: it is drawn as the user had it, whole, and waits in
      // attention, where Keep mine saves that version over the server's
      // and Use cloud drops it. Edits made on top of it are whole too, so
      // they keep it. Work that can't be read even so is left off the page.
      noLongerFits[key] = (opId: head.opId, serverRevision: over?.revision);
      final whole = drawnFrom([for (final op in ops) op.withMerge(null)]);
      if (whole != null && _drawable(whole.drawn)) work[key] = whole;
    }
    if (noLongerFits.isNotEmpty) {
      unawaited(queueNotifier.holdWorkThatNoLongerFits(noLongerFits));
    }
    return work;
  }

  /// Whether hydration can read [drawn] as the page would draw it: an
  /// element its kind decodes, a lineup group its row reads as, page
  /// settings that parse.
  bool _drawable(_NormalizedEntity drawn) {
    if (drawn.deleted) return true;
    try {
      switch (drawn.overlayEntityType) {
        case ActivePageOverlayEntityType.pageDescriptor:
          return true;
        case ActivePageOverlayEntityType.pageContent:
          final settings = cloudObjectPayloadOrNull(
              _decodeObject(drawn.payload)['settings']);
          if (settings != null && settings.isNotEmpty) {
            StrategySettings.fromJson(settings);
          }
          return true;
        case ActivePageOverlayEntityType.element:
          final payload = cloudObjectPayload(drawn.payload);
          final data = cloudPayloadData(payload);
          final elementType =
              data['elementType'] as String? ?? payload['kind'] as String?;
          return elementType != null &&
              decodeCloudElement(elementType, data) != null;
        case ActivePageOverlayEntityType.lineup:
          lineUpGraphFromCloudRows([
            CloudLineupRow(
              publicId: drawn.key.entityId!,
              payload: cloudObjectPayload(drawn.payload),
            ),
          ]);
          return true;
      }
    } catch (_) {
      return false;
    }
  }

  /// [op] drawn over [onto] (the entity as the server, or the op before it,
  /// has it): the entity once [op] lands, and the version [op] was made
  /// against, which an edit of what is drawn is checked against. Null for
  /// work that draws nothing on the page. Element payloads it writes are
  /// read as server rows are, on the strategy's map [mapData] (see
  /// upgradeCloudPayload): an older build may have queued them.
  ({_NormalizedEntity entity, _NormalizedEntity? base})? _drawQueuedOp(
    EntitySyncKey key,
    StrategyOp op,
    _NormalizedEntity? onto, {
    required String mapData,
  }) {
    final live = onto == null || onto.deleted ? null : onto;
    final type = key.overlayType;
    if (type == null) return null;
    final map = Maps.mapNames.entries
        .where((entry) => entry.value == mapData)
        .firstOrNull
        ?.key;
    CloudPayload asRead(CloudPayload payload) =>
        map == null || key.kind != EntitySyncKeyKind.element
            ? payload
            : upgradeCloudPayload(payload, map);
    _NormalizedEntity entity(Object payload, int? sortIndex) =>
        _NormalizedEntity(
          key: key,
          overlayEntityType: type,
          payload: payload,
          sortIndex: sortIndex,
          revision: onto?.revision ?? 0,
          deleted: false,
        );
    switch (op) {
      case PagePatchOp(:final payload, :final expectedPageRevision):
        final isAttack = payload['isAttack'];
        // A rename: the page name is not drawn from here.
        if (live == null || isAttack is! bool) return null;
        return (
          entity: live.copyWith(payload: <String, dynamic>{
            ..._decodeObject(live.payload),
            'isAttack': isAttack,
          }),
          base: live.copyWith(revision: expectedPageRevision, mergeable: false),
        );
      case PageContentPatchOp(
          :final settings,
          :final expectedPageContentRevision
        ):
        if (live == null) return null;
        return (
          entity: live.copyWith(payload: <String, dynamic>{
            'settings': settings,
          }),
          base: live.copyWith(
            revision: expectedPageContentRevision,
            mergeable: false,
          ),
        );
      case ElementAddOp(:final payload, :final sortIndex) ||
            LineupAddOp(:final payload, :final sortIndex):
        return (entity: entity(asRead(payload), sortIndex), base: onto);
      case ElementPatchOp() || LineupPatchOp():
        final sent = op.payload;
        final written =
            sent == null ? live?.payload : asRead(cloudObjectPayload(sent));
        final expected = op.expectedRevision!;
        if (written == null) return null;
        final lineup = op is LineupPatchOp;
        final merge = op.merge;
        if (merge != null) {
          // Over a row the server no longer has (the patch will be refused
          // as deleted), the user's version as they have it.
          final merged = live == null
              ? written
              : mergedPayload(live.payload, written, merge, lineup: lineup);
          final drawnOver = live ?? entity(written, op.sortIndex);
          final baseOfFields =
              payloadAtMergeBase(drawnOver.payload, merge, lineup: lineup);
          if (merged != null && baseOfFields != null) {
            final moves = merge.fields.contains(placeMergeField);
            final basePlace = merge.base?[placeMergeField];
            return (
              entity: drawnOver.copyWith(
                payload: merged,
                sortIndex: moves || live == null
                    ? op.sortIndex ?? drawnOver.sortIndex
                    : drawnOver.sortIndex,
              ),
              base: drawnOver.copyWith(
                payload: baseOfFields,
                sortIndex:
                    moves && basePlace is int ? basePlace : drawnOver.sortIndex,
                revision: expected,
                deleted: false,
              ),
            );
          }
        }
        // A whole write: the item as the user has it, and every edit of
        // it after this one whole too, claiming the revision this one did.
        final whole = entity(written, op.sortIndex ?? live?.sortIndex ?? 0);
        return (
          entity: whole,
          base: (live ?? whole).copyWith(
            revision: expected,
            deleted: false,
            mergeable: false,
          ),
        );
      case ElementReorderOp(:final sortIndex) ||
            LineupReorderOp(:final sortIndex):
        if (live == null) return null;
        return (
          entity: live.copyWith(sortIndex: sortIndex),
          base: live.copyWith(revision: op.expectedRevision, mergeable: false),
        );
      case ElementDeleteOp() || LineupDeleteOp():
        if (live == null) return null;
        return (
          entity: live.copyWith(deleted: true),
          base: live.copyWith(revision: op.expectedRevision, mergeable: false),
        );
      default:
        return null;
    }
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

  /// [receivedOn] is the connection [snapshot]'s page answer was received
  /// on (see liveStampForEdits).
  Map<EntitySyncKey, _NormalizedEntity> _normalizedRemoteEntities(
    RemoteEditorSnapshot snapshot,
    String pageId, {
    int? receivedOn,
  }) {
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
        receivedOn: receivedOn,
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
        receivedOn: receivedOn,
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
        receivedOn: receivedOn,
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
        receivedOn: receivedOn,
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
        _drawnWorkByKey[key]?.drawn.sortIndex ??
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
            for (final key in _drawnWorkByKey.keys)
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
          ..._drawnWorkByKey.keys,
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
            expectedElementRevision: _claimableRevision(overlay, baseRevision),
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
                build: (merge, sortIndex, expectedRevision) => ElementPatchOp(
                  opId: const Uuid().v4(),
                  elementPublicId: entityId,
                  pagePublicId: pageId,
                  payload: payload,
                  sortIndex: sortIndex,
                  expectedElementRevision: expectedRevision,
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
            expectedLineupRevision: _claimableRevision(overlay, baseRevision),
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
                build: (merge, sortIndex, expectedRevision) => LineupPatchOp(
                  opId: const Uuid().v4(),
                  lineupPublicId: entityId,
                  pagePublicId: pageId,
                  payload: payload,
                  sortIndex: sortIndex,
                  expectedLineupRevision: expectedRevision,
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
    required StrategyOp Function(
      FieldMerge? merge,
      int? sortIndex,
      int expectedRevision,
    ) build,
  }) {
    final base = _hydratedBaseByEntityKey[overlay.entityKey];
    final fields = base == null ||
            base.deleted ||
            !base.mergeable ||
            base.revision != overlay.baseRevision
        ? null
        : lineup
            ? lineupMergeFields(base.payload, payload,
                normalize: _withFieldDefaults)
            : elementMergeFields(base.payload, payload,
                normalize: _withFieldDefaults);
    if (base == null || fields == null) {
      // A whole write claims no newer revision than the one at which the
      // server held exactly what this client drew.
      final claimable = base == null
          ? overlay.baseRevision!
          : min(overlay.baseRevision!, base.claimableRevision);
      return build(null, overlay.desiredSortIndex, claimable);
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
      overlay.baseRevision!,
    );
  }

  /// The revision a revision-checked write of [overlay]'s entity may claim:
  /// [revision] (its overlay's base), or older when the server at that
  /// revision also holds fields this client never drew (see
  /// _NormalizedEntity.claimableRevision).
  int _claimableRevision(ActivePageOverlayEntry overlay, int revision) {
    final base = _hydratedBaseByEntityKey[overlay.entityKey];
    return base == null ? revision : min(revision, base.claimableRevision);
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
    int? claimableRevision,
    this.receivedOn,
    this.mergeable = true,
  }) : _claimableRevision = claimableRevision;

  final EntitySyncKey key;
  final ActivePageOverlayEntityType overlayEntityType;
  final Object payload;
  final int? sortIndex;
  final int revision;
  final bool deleted;
  final int? _claimableRevision;

  /// As a base: the connection the server answer it came from was received
  /// on (see StrategyOpQueueNotifier.liveStamp); null when it came from
  /// anything but a live answer.
  final int? receivedOn;

  /// As a base: whether an edit of it may be merged by field. False under
  /// a whole write from the outbox, so the edits after it are whole too.
  final bool mergeable;

  _NormalizedEntity copyWith({
    Object? payload,
    int? sortIndex,
    int? revision,
    bool? deleted,
    int? receivedOn,
    bool? mergeable,
  }) =>
      _NormalizedEntity(
        key: key,
        overlayEntityType: overlayEntityType,
        payload: payload ?? this.payload,
        sortIndex: sortIndex ?? this.sortIndex,
        revision: revision ?? this.revision,
        deleted: deleted ?? this.deleted,
        claimableRevision: revision == null ? _claimableRevision : null,
        receivedOn: receivedOn ?? this.receivedOn,
        mergeable: mergeable ?? this.mergeable,
      );

  /// The revision at which the server held exactly [payload]: what a whole,
  /// revision-checked write from it may claim. Behind [revision] once a
  /// merge from this client landed, since the server then also holds a
  /// teammate's fields that [payload] (what this client sent) lacks.
  int get claimableRevision => _claimableRevision ?? revision;

  _NormalizedEntity withClaimableRevision(int claimable) => _NormalizedEntity(
        key: key,
        overlayEntityType: overlayEntityType,
        payload: payload,
        sortIndex: sortIndex,
        revision: revision,
        deleted: deleted,
        claimableRevision: claimable,
        receivedOn: receivedOn,
        mergeable: mergeable,
      );
}

/// Outbox work for one entity that the canvas drew over the server's
/// version of it ([over], null when the server has none): what the entity
/// looks like once each op lands ([layers], the op sent first, then the one
/// queued behind it), and [base], the version the newest op was made
/// against.
class _DrawnWork {
  const _DrawnWork({
    required this.over,
    required this.layers,
    required this.base,
    this.landedAt,
  });

  final _NormalizedEntity? over;
  final List<({String opId, _NormalizedEntity entity})> layers;
  final _NormalizedEntity? base;

  /// Set once the last of the work has landed: the revision it landed at.
  /// It stays drawn until a server read at or past that revision shows it,
  /// so an older answer arriving late can't take it off the page.
  final int? landedAt;

  /// What the canvas shows.
  _NormalizedEntity get drawn => layers.last.entity;
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
