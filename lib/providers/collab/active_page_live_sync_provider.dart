import 'dart:convert';
import 'dart:developer';
import 'dart:math' show max;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
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
    this.unsyncableLineupKeys = const <EntitySyncKey>{},
  });

  final String? strategyPublicId;
  final String? activePageId;
  final String? hydratedPageId;
  final Set<EntitySyncKey> hydratedEntityKeys;
  final Map<EntitySyncKey, int> remoteBaseRevisionByEntity;
  final Map<EntitySyncKey, ActivePageOverlayEntry> overlayByEntityKey;
  final List<AckedEntityIntent> lastAckBatch;

  /// Lineup rows live sync refused to send because the canvas holds a broken
  /// lineup: rows hydration would not draw back (a link whose origin or
  /// landing is missing, an origin or landing no link uses) and the missing
  /// ends themselves. Sending them would store rows every reader skips or
  /// half-delete the lineup, so the sync status shows attention while any
  /// remain.
  final Set<EntitySyncKey> unsyncableLineupKeys;

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
    Set<EntitySyncKey>? unsyncableLineupKeys,
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
      unsyncableLineupKeys: unsyncableLineupKeys ?? this.unsyncableLineupKeys,
    );
  }
}

final activePageLiveSyncProvider =
    NotifierProvider<ActivePageLiveSyncNotifier, ActivePageLiveSyncState>(
  ActivePageLiveSyncNotifier.new,
);

class ActivePageLiveSyncNotifier extends Notifier<ActivePageLiveSyncState> {
  // Live reads can advance while local work blocks rehydration. Outbound diffs
  // must stay based on the server state that was actually loaded into canvas.
  final Map<EntitySyncKey, _NormalizedEntity> _hydratedBaseByEntityKey = {};
  final Set<EntitySyncKey> _remoteAdoptionPending = {};

  @override
  ActivePageLiveSyncState build() {
    return const ActivePageLiveSyncState();
  }

  void reset() {
    _hydratedBaseByEntityKey.clear();
    _remoteAdoptionPending.clear();
    state = const ActivePageLiveSyncState();
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
    if (strategyChanged) {
      _hydratedBaseByEntityKey.clear();
      _remoteAdoptionPending.clear();
    }
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

  void markPageHydrated({
    required String strategyPublicId,
    required String pageId,
    required RemoteEditorSnapshot snapshot,
  }) {
    setContext(strategyPublicId: strategyPublicId, activePageId: pageId);
    final matchesPage = snapshot.header.publicId == strategyPublicId &&
        snapshot.activePage?.page.publicId == pageId;
    // The base is what the canvas drew. A lineup row hydration skipped was
    // never shown, so no outbound diff may change or delete it.
    final undrawnLineups = matchesPage
        ? _undrawnRemoteLineups(snapshot, pageId)
        : const <EntitySyncKey>{};
    final remoteEntities = {
      if (matchesPage)
        for (final entry in _normalizedRemoteEntities(snapshot, pageId).entries)
          if (!undrawnLineups.contains(entry.key)) entry.key: entry.value,
    };
    _hydratedBaseByEntityKey.removeWhere((key, _) => key.pageId == pageId);
    _hydratedBaseByEntityKey.addAll(remoteEntities);
    _remoteAdoptionPending.removeWhere((key) => key.pageId == pageId);
    final remoteRevisions = Map<EntitySyncKey, int>.from(
      state.remoteBaseRevisionByEntity,
    )..removeWhere((key, _) => key.pageId == pageId);
    for (final entry in remoteEntities.entries) {
      remoteRevisions[entry.key] = entry.value.revision;
    }
    state = state.copyWith(
      hydratedPageId: pageId,
      hydratedEntityKeys: _normalizedLocalEntities(pageId).keys.toSet(),
      remoteBaseRevisionByEntity: remoteRevisions,
    );
  }

  /// Drops [pageId]'s overlays that no op in the queue carries any more.
  ///
  /// An overlay holds local intent until the server has it. Once its op has
  /// landed, the server's snapshot is the truth, and it may already hold a
  /// teammate's newer change to that entity; painting the overlay would show
  /// the older local version and the next sync would write it back. Call this
  /// before projecting a page for hydration. Acks usually clear overlays in
  /// syncLocalPage, but that skips a page that is being rehydrated or is not
  /// the active one. A page only rehydrates once its local edits are queued
  /// (the session waits for pending cloud sync), so this never drops unsent
  /// work.
  void dropSatisfiedOverlays(String pageId) {
    final queue = ref.read(strategyOpQueueProvider);
    bool isPending(EntitySyncKey key) =>
        queue.queuedByEntityKey.containsKey(key) ||
        queue.inFlightByEntityKey.containsKey(key) ||
        queue.successorByEntityKey.containsKey(key) ||
        queue.pausedByEntityKey.containsKey(key) ||
        queue.attentionByEntityKey.containsKey(key);
    final overlays = Map<EntitySyncKey, ActivePageOverlayEntry>.from(
      state.overlayByEntityKey,
    )..removeWhere((key, _) => key.pageId == pageId && !isPending(key));
    if (overlays.length == state.overlayByEntityKey.length) return;
    state = state.copyWith(overlayByEntityKey: overlays);
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

      _hydratedBaseByEntityKey[key] = accepted;
      remoteRevisions[key] = revision;
      final overlay = overlays[key];
      if (overlay != null) {
        overlays[key] = overlay.copyWith(
          baseRevision: revision,
          baseDeleted: accepted.deleted,
        );
      }
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
    final heldBackLineups = _heldBackLineups(pageId);
    final unsyncableLineups = <EntitySyncKey>{};

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

      // Never author a lineup row that hydration would not draw (every
      // reader skips it, so it reads as a deletion nobody made), nor delete
      // an end a local link still names. Keep what is already overlaid or
      // queued for it and show attention instead.
      if (heldBackLineups.contains(key)) {
        unsyncableLineups.add(key);
        if (!state.unsyncableLineupKeys.contains(key)) {
          AppErrorReporter.reportError(
            'A lineup could not be synced because its origin or landing '
            'spot is missing ($key).',
            source: 'active_page_live_sync:empty_lineup',
            promptUser: false,
          );
        }
        if (existingOverlay == null && retainedOp != null) {
          retainedDesiredOps[key] = retainedOp;
        }
        continue;
      }

      final shouldPreserveTouched = hasQueued || hasInFlight || hasSuccessor;
      final matchesRemote = _entitiesEquivalent(local, remote);
      final matchesHydratedBase = _entitiesEquivalent(local, hydratedBase);
      final shouldUseRetainedIntent = hasQueued ||
          (!hasInFlight && hasSuccessor) ||
          (local == null && hydratedBase == null);

      // A restored queue entry has no in-memory overlay. If the canvas still
      // matches its hydrated base, the durable op is the only local intent and
      // must remain desired until it lands or the user changes that entity.
      if (existingOverlay == null &&
          retainedOp != null &&
          shouldUseRetainedIntent &&
          matchesHydratedBase) {
        retainedDesiredOps[key] = retainedOp;
        _debugLog('overlay.keep $key reason=durable_queue_only');
        continue;
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
        if (_legacyGroupConversionPending(
          pageId: pageId,
          base: hydratedBase ?? remote,
          localEntities: localEntities,
          remoteEntities: remoteEntities,
        )) {
          nextOverlay.remove(key);
          _debugLog('overlay.skip $key reason=conversion_not_landed');
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
      unsyncableLineupKeys: {
        ...state.unsyncableLineupKeys.where((key) => key.pageId != pageId),
        ...unsyncableLineups,
      },
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
        ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex)),
      lineups: remoteLineups.values.toList(growable: false)
        ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex)),
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

    final elementEnvelopes = _collectLocalElementEnvelopes();
    for (var index = 0; index < elementEnvelopes.length; index++) {
      final envelope = elementEnvelopes[index];
      final key = EntitySyncKey.element(pageId, envelope.publicId);
      entities[key] = _NormalizedEntity(
        key: key,
        overlayEntityType: ActivePageOverlayEntityType.element,
        payload: cloudElementPayload(
            kind: envelope.kind.name, data: envelope.payload),
        sortIndex: index,
        revision: 0,
        deleted: false,
      );
    }

    // One row per origin, landing and link. A row keeps the sortIndex it was
    // first sent with and new rows go after the page's highest: order is
    // never re-sent, so removing one lineup does not rewrite every row after
    // it and collide with a teammate editing one of them.
    // A row that another client already wrote (both converted the same
    // legacy group) takes the server's sortIndex, so the same content reads
    // as the same row instead of an add the server refuses.
    bool isPageLineup(EntitySyncKey key) =>
        key.pageId == pageId && key.kind == EntitySyncKeyKind.lineup;
    final remoteSortIndex = {
      for (final lineup in ref
              .read(remoteEditorSnapshotProvider)
              .valueOrNull
              ?.lineupsByPage[pageId] ??
          const <RemoteLineup>[])
        if (!lineup.deleted)
          EntitySyncKey.lineup(pageId, lineup.publicId): lineup.sortIndex,
    };
    int? knownSortIndex(EntitySyncKey key) =>
        state.overlayByEntityKey[key]?.desiredSortIndex ??
        _hydratedBaseByEntityKey[key]?.sortIndex ??
        remoteSortIndex[key];
    var nextSortIndex = 1 +
        [
          for (final key in _hydratedBaseByEntityKey.keys)
            if (isPageLineup(key)) knownSortIndex(key) ?? 0,
          for (final key in state.overlayByEntityKey.keys)
            if (isPageLineup(key)) knownSortIndex(key) ?? 0,
        ].fold<int>(-1, max);
    for (final row in cloudLineupRows(ref.read(lineUpProvider).graph)) {
      final key = EntitySyncKey.lineup(pageId, row.publicId);
      entities[key] = _NormalizedEntity(
        key: key,
        overlayEntityType: ActivePageOverlayEntityType.lineup,
        payload: row.payload,
        sortIndex: knownSortIndex(key) ?? nextSortIndex++,
        revision: 0,
        deleted: false,
      );
    }

    return entities;
  }

  /// Lineup rows live sync holds back from a broken local graph: rows the
  /// canvas holds that hydration would not draw back (a link whose origin or
  /// landing is missing, an origin or landing no link uses), judged by the
  /// reader hydration uses, and the missing ends such a link still names, so
  /// a broken lineup is neither half-written nor half-deleted.
  Set<EntitySyncKey> _heldBackLineups(String pageId) {
    EntitySyncKey key(String rowId) => EntitySyncKey.lineup(pageId, rowId);
    final graph = ref.read(lineUpProvider).graph;
    final rows = cloudLineupRows(graph);
    final drawn = lineUpGraphFromCloudRows(rows).drawnRowIds;
    final originIds = {for (final origin in graph.origins) origin.id};
    final landingIds = {for (final landing in graph.landings) landing.id};
    return {
      for (final row in rows)
        if (!drawn.contains(row.publicId)) key(row.publicId),
      for (final link in graph.links) ...[
        if (!originIds.contains(link.originId))
          key(cloudLineupRowId(CloudLineupKind.origin, link.originId)),
        if (!landingIds.contains(link.landingId))
          key(cloudLineupRowId(CloudLineupKind.landing, link.landingId)),
      ],
    };
  }

  /// Whether [base] is a legacy group row whose conversion has not landed.
  ///
  /// A group converts by adding its graph rows and deleting the group. The
  /// delete waits until every row the canvas still shows from it is live on
  /// the server, so an add that fails (and keeps failing) never leaves the
  /// lineup with neither form: the group stays, and a reload still shows it.
  /// Rows the canvas no longer shows (the user deleted that lineup) do not
  /// hold the delete back.
  bool _legacyGroupConversionPending({
    required String pageId,
    required _NormalizedEntity? base,
    required Map<EntitySyncKey, _NormalizedEntity> localEntities,
    required Map<EntitySyncKey, _NormalizedEntity> remoteEntities,
  }) {
    final payload = base?.payload;
    if (payload is! Map<String, dynamic>) return false;
    final rowIds = legacyGroupRowIds(payload);
    if (rowIds == null) return false;
    return rowIds.any((rowId) {
      final key = EntitySyncKey.lineup(pageId, rowId);
      final remote = remoteEntities[key];
      return localEntities.containsKey(key) &&
          (remote == null || remote.deleted);
    });
  }

  /// The page's live lineup rows that hydration skipped.
  Set<EntitySyncKey> _undrawnRemoteLineups(
    RemoteEditorSnapshot snapshot,
    String pageId,
  ) {
    final live = [
      for (final lineup
          in snapshot.lineupsByPage[pageId] ?? const <RemoteLineup>[])
        if (!lineup.deleted)
          CloudLineupRow(publicId: lineup.publicId, payload: lineup.payload),
    ];
    final drawn = lineUpGraphFromCloudRows(live).drawnRowIds;
    return {
      for (final row in live)
        if (!drawn.contains(row.publicId))
          EntitySyncKey.lineup(pageId, row.publicId),
    };
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
            : ElementPatchOp(
                opId: const Uuid().v4(),
                elementPublicId: entityId,
                pagePublicId: pageId,
                payload: payload,
                sortIndex: overlay.desiredSortIndex,
                expectedElementRevision: overlay.baseRevision!,
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
            : LineupPatchOp(
                opId: const Uuid().v4(),
                lineupPublicId: entityId,
                pagePublicId: pageId,
                payload: payload,
                sortIndex: overlay.desiredSortIndex,
                expectedLineupRevision: overlay.baseRevision!,
              );
    }
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
