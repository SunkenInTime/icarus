import 'dart:convert';
import 'dart:developer';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
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
    this.remoteBaseRevisionByEntity = const <EntitySyncKey, int>{},
    this.overlayByEntityKey = const <EntitySyncKey, ActivePageOverlayEntry>{},
    this.lastAckBatch = const <AckedEntityIntent>[],
  });

  final String? strategyPublicId;
  final String? activePageId;
  final Map<EntitySyncKey, int> remoteBaseRevisionByEntity;
  final Map<EntitySyncKey, ActivePageOverlayEntry> overlayByEntityKey;
  final List<AckedEntityIntent> lastAckBatch;

  ActivePageLiveSyncState copyWith({
    String? strategyPublicId,
    String? activePageId,
    bool clearActivePageId = false,
    Map<EntitySyncKey, int>? remoteBaseRevisionByEntity,
    Map<EntitySyncKey, ActivePageOverlayEntry>? overlayByEntityKey,
    List<AckedEntityIntent>? lastAckBatch,
  }) {
    return ActivePageLiveSyncState(
      strategyPublicId: strategyPublicId ?? this.strategyPublicId,
      activePageId:
          clearActivePageId ? null : (activePageId ?? this.activePageId),
      remoteBaseRevisionByEntity:
          remoteBaseRevisionByEntity ?? this.remoteBaseRevisionByEntity,
      overlayByEntityKey: overlayByEntityKey ?? this.overlayByEntityKey,
      lastAckBatch: lastAckBatch ?? this.lastAckBatch,
    );
  }
}

final activePageLiveSyncProvider =
    NotifierProvider<ActivePageLiveSyncNotifier, ActivePageLiveSyncState>(
  ActivePageLiveSyncNotifier.new,
);

class ActivePageLiveSyncNotifier extends Notifier<ActivePageLiveSyncState> {
  @override
  ActivePageLiveSyncState build() {
    return const ActivePageLiveSyncState();
  }

  void reset() {
    state = const ActivePageLiveSyncState();
  }

  void setContext({
    required String? strategyPublicId,
    required String? activePageId,
  }) {
    state = state.copyWith(
      strategyPublicId: strategyPublicId,
      activePageId: activePageId,
      clearActivePageId: activePageId == null,
      remoteBaseRevisionByEntity: strategyPublicId == state.strategyPublicId
          ? state.remoteBaseRevisionByEntity
          : const <EntitySyncKey, int>{},
      overlayByEntityKey: strategyPublicId == state.strategyPublicId
          ? state.overlayByEntityKey
          : const <EntitySyncKey, ActivePageOverlayEntry>{},
    );
  }

  bool hasOverlayForPage(String pageId) {
    return state.overlayByEntityKey.keys.any((key) => pageIdForEntityKey(key) == pageId);
  }

  void recordAckBatch(List<AckedEntityIntent> intents) {
    state = state.copyWith(lastAckBatch: intents);
  }

  Map<EntitySyncKey, StrategyOp> syncLocalPage({
    required String strategyPublicId,
    required String pageId,
  }) {
    setContext(strategyPublicId: strategyPublicId, activePageId: pageId);
    final snapshot = ref.read(remoteStrategySnapshotProvider).valueOrNull;
    if (snapshot == null) {
      return const <EntitySyncKey, StrategyOp>{};
    }

    final queueState = ref.read(strategyOpQueueProvider);
    final remoteEntities = _normalizedRemoteEntities(snapshot, pageId);
    final localEntities = _normalizedLocalEntities(pageId);
    final remoteRevisions = Map<EntitySyncKey, int>.from(
      state.remoteBaseRevisionByEntity,
    );

    for (final entry in remoteEntities.entries) {
      remoteRevisions[entry.key] = entry.value.revision;
    }

    final pageKeys = <EntitySyncKey>{
      ...remoteEntities.keys,
      ...localEntities.keys,
      ...state.overlayByEntityKey.keys.where((key) => pageIdForEntityKey(key) == pageId),
      ...queueState.queuedByEntityKey.keys.where((key) => pageIdForEntityKey(key) == pageId),
      ...queueState.inFlightByEntityKey.keys.where((key) => pageIdForEntityKey(key) == pageId),
    };

    final nextOverlay = Map<EntitySyncKey, ActivePageOverlayEntry>.from(
      state.overlayByEntityKey,
    );

    for (final key in pageKeys) {
      final remote = remoteEntities[key];
      final local = localEntities[key];
      final hasQueued = queueState.queuedByEntityKey.containsKey(key);
      final hasInFlight = queueState.inFlightByEntityKey.containsKey(key);
      final existingOverlay = state.overlayByEntityKey[key];

      final shouldPreserveTouched = hasQueued || hasInFlight || existingOverlay != null;
      final matchesRemote = _entitiesEquivalent(local, remote);

      if (matchesRemote && !hasQueued && !hasInFlight) {
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
          baseRevision: remote?.revision ?? existingOverlay?.baseRevision ?? 0,
        );
        nextOverlay[key] = overlay;
        _debugLog('overlay.keep $key reason=pending_reconciliation');
        continue;
      }

      if (local == null && remote != null) {
        final overlay = ActivePageOverlayEntry(
          entityKey: key,
          entityType: remote.overlayEntityType,
          desiredPayload: null,
          desiredSortIndex: null,
          deletion: true,
          baseRevision: remote.revision,
          dirtyAt: DateTime.now(),
        );
        nextOverlay[key] = overlay;
        _debugLog('overlay.upsert $key deletion=true');
        continue;
      }

      if (local != null) {
        final overlay = _overlayFromDesiredEntity(
          key: key,
          desired: local,
          baseRevision: remote?.revision ?? existingOverlay?.baseRevision ?? 0,
        );
        nextOverlay[key] = overlay;
        _debugLog(
          'overlay.upsert $key deletion=false baseRevision=${overlay.baseRevision}',
        );
      }
    }

    final desiredOpsByEntityKey = <EntitySyncKey, StrategyOp>{};
    for (final entry in nextOverlay.entries) {
      final key = entry.key;
      if (pageIdForEntityKey(key) != pageId) {
        continue;
      }
      final remote = remoteEntities[key];
      final overlay = entry.value;
      if (_overlayMatchesRemote(overlay, remote)) {
        continue;
      }
      final op = _strategyOpFromOverlay(pageId: pageId, overlay: overlay, remote: remote);
      if (op != null) {
        desiredOpsByEntityKey[key] = op;
      }
    }

    state = state.copyWith(
      strategyPublicId: strategyPublicId,
      activePageId: pageId,
      remoteBaseRevisionByEntity: remoteRevisions,
      overlayByEntityKey: nextOverlay,
    );

    return desiredOpsByEntityKey;
  }

  ActivePageProjectedState? projectPageState({
    required String strategyPublicId,
    required String pageId,
  }) {
    setContext(strategyPublicId: strategyPublicId, activePageId: pageId);
    final snapshot = ref.read(remoteStrategySnapshotProvider).valueOrNull;
    if (snapshot == null) {
      return null;
    }

    final page = snapshot.pages.firstWhere(
      (entry) => entry.publicId == pageId,
      orElse: () => snapshot.pages.first,
    );

    final remoteElements = {
      for (final element
          in (snapshot.elementsByPage[page.publicId] ?? const <RemoteElement>[]))
        if (!element.deleted)
          elementEntityKey(page.publicId, element.publicId): ProjectedPageElement(
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
          lineupEntityKey(page.publicId, lineup.publicId): ProjectedPageLineup(
            publicId: lineup.publicId,
            payload: lineup.payload,
            sortIndex: lineup.sortIndex,
          ),
    };

    var projectedSettingsJson = page.settings;
    var projectedIsAttack = page.isAttack;

    final pageOverlays = state.overlayByEntityKey.entries.where(
      (entry) => pageIdForEntityKey(entry.key) == page.publicId,
    );
    for (final entry in pageOverlays) {
      final overlay = entry.value;
      switch (overlay.entityType) {
        case ActivePageOverlayEntityType.pageSettings:
          if (overlay.desiredPayload == null) {
            continue;
          }
          final decoded = _decodeObject(overlay.desiredPayload!);
          projectedSettingsJson = decoded['settings'] as String?;
          final isAttack = decoded['isAttack'];
          if (isAttack is bool) {
            projectedIsAttack = isAttack;
          }
          continue;
        case ActivePageOverlayEntityType.element:
          if (overlay.deletion) {
            remoteElements.remove(entry.key);
            continue;
          }
          final elementId = entityIdForEntityKey(entry.key);
          if (elementId == null || overlay.desiredPayload == null) {
            continue;
          }
          final decoded = _decodeObject(overlay.desiredPayload!);
          remoteElements[entry.key] = ProjectedPageElement(
            publicId: elementId,
            elementType: decoded['elementType'] as String? ?? 'generic',
            payload: overlay.desiredPayload!,
            sortIndex: overlay.desiredSortIndex ?? 0,
          );
          continue;
        case ActivePageOverlayEntityType.lineup:
          if (overlay.deletion) {
            remoteLineups.remove(entry.key);
            continue;
          }
          final lineupId = entityIdForEntityKey(entry.key);
          if (lineupId == null || overlay.desiredPayload == null) {
            continue;
          }
          remoteLineups[entry.key] = ProjectedPageLineup(
            publicId: lineupId,
            payload: overlay.desiredPayload!,
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
      settingsJson: projectedSettingsJson,
      elements: remoteElements.values.toList(growable: false)
        ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex)),
      lineups: remoteLineups.values.toList(growable: false)
        ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex)),
    );
  }

  Map<String, dynamic> _decodeObject(String payload) {
    final decoded = jsonDecode(payload);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    return const <String, dynamic>{};
  }

  Map<EntitySyncKey, _NormalizedEntity> _normalizedRemoteEntities(
    RemoteStrategySnapshot snapshot,
    String pageId,
  ) {
    final page = snapshot.pages.firstWhere(
      (entry) => entry.publicId == pageId,
      orElse: () => snapshot.pages.first,
    );

    final entities = <EntitySyncKey, _NormalizedEntity>{
      pageSettingsEntityKey(page.publicId): _NormalizedEntity(
        key: pageSettingsEntityKey(page.publicId),
        overlayEntityType: ActivePageOverlayEntityType.pageSettings,
        payload: _pagePayload(
          settingsJson: page.settings,
          isAttack: page.isAttack,
        ),
        sortIndex: null,
        revision: page.revision,
        deleted: false,
      ),
    };

    for (final element
        in (snapshot.elementsByPage[page.publicId] ?? const <RemoteElement>[])) {
      if (element.deleted) {
        continue;
      }
      final key = elementEntityKey(page.publicId, element.publicId);
      entities[key] = _NormalizedEntity(
        key: key,
        overlayEntityType: ActivePageOverlayEntityType.element,
        payload: element.payload,
        sortIndex: element.sortIndex,
        revision: element.revision,
        deleted: false,
      );
    }

    for (final lineup
        in (snapshot.lineupsByPage[page.publicId] ?? const <RemoteLineup>[])) {
      if (lineup.deleted) {
        continue;
      }
      final key = lineupEntityKey(page.publicId, lineup.publicId);
      entities[key] = _NormalizedEntity(
        key: key,
        overlayEntityType: ActivePageOverlayEntityType.lineup,
        payload: lineup.payload,
        sortIndex: lineup.sortIndex,
        revision: lineup.revision,
        deleted: false,
      );
    }

    return entities;
  }

  Map<EntitySyncKey, _NormalizedEntity> _normalizedLocalEntities(String pageId) {
    final entities = <EntitySyncKey, _NormalizedEntity>{};

    final pageKey = pageSettingsEntityKey(pageId);
    entities[pageKey] = _NormalizedEntity(
      key: pageKey,
      overlayEntityType: ActivePageOverlayEntityType.pageSettings,
      payload: _pagePayload(
        settingsJson: ref.read(strategySettingsProvider.notifier).toJson(),
        isAttack: ref.read(mapProvider).isAttack,
      ),
      sortIndex: null,
      revision: 0,
      deleted: false,
    );

    final elementEnvelopes = _collectLocalElementEnvelopes();
    for (var index = 0; index < elementEnvelopes.length; index++) {
      final envelope = elementEnvelopes[index];
      final key = elementEntityKey(pageId, envelope.publicId);
      entities[key] = _NormalizedEntity(
        key: key,
        overlayEntityType: ActivePageOverlayEntityType.element,
        payload: jsonEncode(envelope.payload),
        sortIndex: index,
        revision: 0,
        deleted: false,
      );
    }

    final lineups = ref.read(lineUpProvider).lineUps;
    for (var index = 0; index < lineups.length; index++) {
      final lineup = lineups[index];
      final key = lineupEntityKey(pageId, lineup.id);
      entities[key] = _NormalizedEntity(
        key: key,
        overlayEntityType: ActivePageOverlayEntityType.lineup,
        payload: jsonEncode(lineup.toJson()),
        sortIndex: index,
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
        ..putIfAbsent('elementType', () => 'agent');
      envelopes.add(
        _CollabElementEnvelope(
          publicId: agent.id,
          payload: payload,
        ),
      );
    }

    for (final ability in ref.read(abilityProvider)) {
      final payload = Map<String, dynamic>.from(ability.toJson())
        ..putIfAbsent('elementType', () => 'ability');
      envelopes.add(
        _CollabElementEnvelope(
          publicId: ability.id,
          payload: payload,
        ),
      );
    }

    for (final drawing in ref.read(drawingProvider).elements) {
      final encoded = jsonDecode(DrawingProvider.objectToJson([drawing])) as List;
      final payload = Map<String, dynamic>.from(
        (encoded.isEmpty ? <String, dynamic>{} : encoded.first) as Map,
      )..putIfAbsent('elementType', () => 'drawing');
      envelopes.add(
        _CollabElementEnvelope(
          publicId: drawing.id,
          payload: payload,
        ),
      );
    }

    for (final text in ref.read(textProvider)) {
      final payload = Map<String, dynamic>.from(text.toJson())
        ..putIfAbsent('elementType', () => 'text');
      envelopes.add(
        _CollabElementEnvelope(
          publicId: text.id,
          payload: payload,
        ),
      );
    }

    for (final image in ref.read(placedImageProvider).images) {
      final payload = Map<String, dynamic>.from(image.toJson())
        ..putIfAbsent('elementType', () => 'image');
      envelopes.add(
        _CollabElementEnvelope(
          publicId: image.id,
          payload: payload,
        ),
      );
    }

    for (final utility in ref.read(utilityProvider)) {
      final payload = Map<String, dynamic>.from(utility.toJson())
        ..putIfAbsent('elementType', () => 'utility');
      envelopes.add(
        _CollabElementEnvelope(
          publicId: utility.id,
          payload: payload,
        ),
      );
    }

    return envelopes;
  }

  ActivePageOverlayEntry _overlayFromDesiredEntity({
    required EntitySyncKey key,
    required _NormalizedEntity desired,
    required int baseRevision,
  }) {
    return ActivePageOverlayEntry(
      entityKey: key,
      entityType: desired.overlayEntityType,
      desiredPayload: desired.payload,
      desiredSortIndex: desired.sortIndex,
      deletion: desired.deleted,
      baseRevision: baseRevision,
      dirtyAt: DateTime.now(),
    );
  }

  StrategyOp? _strategyOpFromOverlay({
    required String pageId,
    required ActivePageOverlayEntry overlay,
    required _NormalizedEntity? remote,
  }) {
    final entityId = entityIdForEntityKey(overlay.entityKey);
    switch (overlay.entityType) {
      case ActivePageOverlayEntityType.pageSettings:
        return StrategyOp(
          opId: const Uuid().v4(),
          kind: StrategyOpKind.patch,
          entityType: StrategyOpEntityType.page,
          entityPublicId: pageId,
          payload: overlay.desiredPayload,
          expectedRevision: remote?.revision ?? overlay.baseRevision,
        );
      case ActivePageOverlayEntityType.element:
        if (entityId == null) {
          return null;
        }
        if (overlay.deletion) {
          return StrategyOp(
            opId: const Uuid().v4(),
            kind: StrategyOpKind.delete,
            entityType: StrategyOpEntityType.element,
            entityPublicId: entityId,
            pagePublicId: pageId,
            expectedRevision: remote?.revision ?? overlay.baseRevision,
          );
        }
        return StrategyOp(
          opId: const Uuid().v4(),
          kind: remote == null ? StrategyOpKind.add : StrategyOpKind.patch,
          entityType: StrategyOpEntityType.element,
          entityPublicId: entityId,
          pagePublicId: pageId,
          payload: overlay.desiredPayload,
          sortIndex: overlay.desiredSortIndex,
          expectedRevision: remote == null ? null : (remote.revision),
        );
      case ActivePageOverlayEntityType.lineup:
        if (entityId == null) {
          return null;
        }
        if (overlay.deletion) {
          return StrategyOp(
            opId: const Uuid().v4(),
            kind: StrategyOpKind.delete,
            entityType: StrategyOpEntityType.lineup,
            entityPublicId: entityId,
            pagePublicId: pageId,
            expectedRevision: remote?.revision ?? overlay.baseRevision,
          );
        }
        return StrategyOp(
          opId: const Uuid().v4(),
          kind: remote == null ? StrategyOpKind.add : StrategyOpKind.patch,
          entityType: StrategyOpEntityType.lineup,
          entityPublicId: entityId,
          pagePublicId: pageId,
          payload: overlay.desiredPayload,
          sortIndex: overlay.desiredSortIndex,
          expectedRevision: remote == null ? null : remote.revision,
        );
    }
  }

  bool _overlayMatchesRemote(
    ActivePageOverlayEntry overlay,
    _NormalizedEntity? remote,
  ) {
    if (overlay.deletion) {
      return remote == null;
    }
    if (remote == null) {
      return false;
    }
    return overlay.desiredPayload == remote.payload &&
        overlay.desiredSortIndex == remote.sortIndex;
  }

  bool _entitiesEquivalent(
    _NormalizedEntity? local,
    _NormalizedEntity? remote,
  ) {
    if (identical(local, remote)) {
      return true;
    }
    if (local == null || remote == null) {
      return false;
    }
    return local.deleted == remote.deleted &&
        local.payload == remote.payload &&
        local.sortIndex == remote.sortIndex &&
        local.overlayEntityType == remote.overlayEntityType;
  }

  String _pagePayload({
    required String? settingsJson,
    required bool isAttack,
  }) {
    return jsonEncode({
      'settings': settingsJson,
      'isAttack': isAttack,
    });
  }

  void _debugLog(String message) {
    assert(() {
      log(message, name: 'active_page_live_sync');
      return true;
    }());
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
  final String payload;
  final int? sortIndex;
  final int revision;
  final bool deleted;
}

class _CollabElementEnvelope {
  const _CollabElementEnvelope({
    required this.publicId,
    required this.payload,
  });

  final String publicId;
  final Map<String, dynamic> payload;
}
