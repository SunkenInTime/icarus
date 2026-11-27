import 'dart:convert';
import 'dart:math' show max, min;

import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/field_merge.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/strategy/canvas_shows.dart';
import 'package:icarus/strategy/cloud_element_decoding.dart';
import 'package:icarus_library/icarus_library.dart' show withFieldDefaults;
import 'package:uuid/uuid.dart';

class LineupGroupMemories {
  LineupGroupMemories(this._learned);

  final void Function() _learned;

  /// Per page, the lineup group each lineup and spot was last drawn from or
  /// written to (see cloudLineupRows), so a group keeps its id and its
  /// lineups while the canvas changes under it. Per page because a page
  /// duplicated before cloud sync repeats its lineup ids. Never forgotten:
  /// an undo can bring back a lineup long after its row moved on.
  final Map<String, Map<String, String>> lineupGroupOfByPage = {};

  /// Records the groups a canvas of [pageId] about to be drawn from cloud
  /// rows uses.
  void noteLineupGroups(String pageId, Map<String, String> groupOf) {
    _rememberLineupGroups(lineupGroupOfByPage[pageId] ??= {}, groupOf);
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
    if (learned) _learned();
  }

  /// The lineup group [itemId] (a lineup, origin or landing) on [pageId]
  /// was last in.
  String? lineupGroupOf(String pageId, String itemId) =>
      lineupGroupOfByPage[pageId]?[itemId];

  LineupGroupMemory lineupGroupMemory(
    String pageId, {
    required RemoteEditorSnapshot? snapshot,
    required Iterable<EntitySyncKey> hydratedBaseKeys,
    required Iterable<EntitySyncKey> Function() overlayKeys,
    required Iterable<EntitySyncKey> drawnWorkKeys,
    required int? Function(EntitySyncKey key) knownSortIndex,
  }) {
    final serverOrder = {
      for (final (index, row)
          in (snapshot?.lineupsByPage[pageId] ?? const <RemoteLineup>[])
              .indexed)
        row.publicId: index,
    };
    final known = [
      for (final key in {
        ...hydratedBaseKeys,
        ...overlayKeys(),
        ...drawnWorkKeys,
      })
        if (key.pageId == pageId && key.kind == EntitySyncKeyKind.lineup)
          if (knownSortIndex(key) case final sortIndex?)
            (id: key.entityId!, sortIndex: sortIndex),
    ]..sort((a, b) => a.sortIndex != b.sortIndex
        ? a.sortIndex.compareTo(b.sortIndex)
        : (serverOrder[a.id] ?? 1 << 30)
            .compareTo(serverOrder[b.id] ?? 1 << 30));
    return LineupGroupMemory(
      groupOf: Map.unmodifiable(lineupGroupOfByPage[pageId] ?? const {}),
      places: {for (final (rank, row) in known.indexed) row.id: rank},
    );
  }
}

/// Whether hydration can read [drawn] as the page would draw it: an
/// element its kind decodes, a lineup group its row reads as, page
/// settings that parse.
bool drawable(NormalizedEntity drawn) {
  if (drawn.deleted) return true;
  try {
    switch (drawn.overlayEntityType) {
      case ActivePageOverlayEntityType.pageDescriptor:
        return true;
      case ActivePageOverlayEntityType.pageContent:
        final settings = cloudObjectPayloadOrNull(
            decodeObject(drawn.payload)['settings']);
        if (settings != null && settings.isNotEmpty) {
          StrategySettings.fromJson(settings);
        }
        return true;
      case ActivePageOverlayEntityType.element:
        final data = cloudPayloadData(drawn.payload);
        final elementType = elementTypeOf(drawn.payload);
        return elementType != null &&
            readCloudElement(elementType, data) is DrawnCloudElement;
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

String? elementTypeOf(Object? payload) => switch ((
      cloudPayloadData(payload)['elementType'],
      payload is Map ? payload['kind'] : null,
    )) {
      (final String type, _) => type,
      (_, final String kind) => kind,
      _ => null,
    };

Map<String, dynamic> decodeObject(Object payload) {
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
Map<EntitySyncKey, NormalizedEntity> normalizedRemoteEntities(
  RemoteEditorSnapshot snapshot,
  String pageId, {
  int? receivedOn,
}) {
  final page = remotePageById(snapshot: snapshot, pageId: pageId);
  if (page == null) {
    return const <EntitySyncKey, NormalizedEntity>{};
  }

  final pageSnapshot = snapshot.activePage;
  if (pageSnapshot == null || pageSnapshot.page.publicId != page.publicId) {
    return const <EntitySyncKey, NormalizedEntity>{};
  }

  final entities = <EntitySyncKey, NormalizedEntity>{
    EntitySyncKey.pageDescriptor(page.publicId): NormalizedEntity(
      key: EntitySyncKey.pageDescriptor(page.publicId),
      overlayEntityType: ActivePageOverlayEntityType.pageDescriptor,
      payload: <String, dynamic>{'isAttack': page.isAttack},
      sortIndex: null,
      revision: page.revision,
      deleted: false,
      receivedOn: receivedOn,
    ),
    EntitySyncKey.pageContent(page.publicId): NormalizedEntity(
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
    entities[key] = NormalizedEntity(
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
    entities[key] = NormalizedEntity(
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

Map<EntitySyncKey, NormalizedEntity> normalizedLocalEntities(
  String pageId,
  CanvasOf canvas, {
  required Iterable<EntitySyncKey> hydratedBaseKeys,
  required Iterable<EntitySyncKey> Function() overlayKeys,
  required Iterable<EntitySyncKey> drawnWorkKeys,
  required int? Function(EntitySyncKey key) knownSortIndex,
  required Map<EntitySyncKey, int> hydratedPositionByKey,
  required Set<EntitySyncKey> heldDeletedKeys,
  required LineupGroupMemories lineupGroupMemories,
}) {
  final entities = <EntitySyncKey, NormalizedEntity>{};

  final descriptorKey = EntitySyncKey.pageDescriptor(pageId);
  entities[descriptorKey] = NormalizedEntity(
    key: descriptorKey,
    overlayEntityType: ActivePageOverlayEntityType.pageDescriptor,
    payload: <String, dynamic>{
      'isAttack': canvas.isAttack,
    },
    sortIndex: null,
    revision: 0,
    deleted: false,
  );
  final unshown = canvas.unshown;
  final settings = canvas.settings.toJson();
  final contentKey = EntitySyncKey.pageContent(pageId);
  entities[contentKey] = NormalizedEntity(
    key: contentKey,
    overlayEntityType: ActivePageOverlayEntityType.pageContent,
    payload: <String, dynamic>{
      'settings': switch (unshown.settings) {
        (:final payload, :final shownInstead)
            when cloudJsonEquivalent(settings, shownInstead.toJson()) =>
          payload,
        _ => settings,
      },
    },
    sortIndex: null,
    revision: 0,
    deleted: false,
  );

  // A row keeps the sortIndex it was first sent with and new rows go after
  // the page's highest. Removing an element or lineup (here or by a
  // teammate) then rewrites no row after it, which would collide with a
  // teammate editing one of them; the server never renumbers either.
  int Function() freshSortIndexes(EntitySyncKeyKind kind) {
    bool onPage(EntitySyncKey key) =>
        key.pageId == pageId && key.kind == kind;
    var next = 1 +
        [
          for (final key in hydratedBaseKeys)
            if (onPage(key)) knownSortIndex(key) ?? 0,
          for (final key in overlayKeys())
            if (onPage(key)) knownSortIndex(key) ?? 0,
          for (final key in drawnWorkKeys)
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
  final previousByKind = <CollabElementKind, (EntitySyncKey, int)>{};
  bool drawnInThisOrder(EntitySyncKey first, EntitySyncKey second) {
    final a = hydratedPositionByKey[first];
    final b = hydratedPositionByKey[second];
    return a != null && b != null && a < b;
  }

  int stackedSortIndex(EntitySyncKey key, CollabElementKind kind) {
    final known = knownSortIndex(key);
    if (heldDeletedKeys.contains(key) && known != null) return known;
    final previous = previousByKind[kind];
    final keep = known != null &&
        (previous == null ||
            known > previous.$2 ||
            (known == previous.$2 && drawnInThisOrder(previous.$1, key)));
    final sortIndex = keep ? known : freshElementSortIndex();
    previousByKind[kind] = (key, sortIndex);
    return sortIndex;
  }

  for (final envelope in collectLocalElementEnvelopes(canvas)) {
    final key = EntitySyncKey.element(pageId, envelope.publicId);
    entities[key] = NormalizedEntity(
      key: key,
      overlayEntityType: ActivePageOverlayEntityType.element,
      payload: cloudElementPayload(
          kind: envelope.kind.name, data: envelope.payload),
      sortIndex: stackedSortIndex(key, envelope.kind),
      revision: 0,
      deleted: false,
    );
  }

  for (final element in unshown.elements) {
    final key = EntitySyncKey.element(pageId, element.publicId);
    entities[key] = NormalizedEntity(
      key: key,
      overlayEntityType: ActivePageOverlayEntityType.element,
      payload: element.payload,
      sortIndex: element.sortIndex,
      revision: 0,
      deleted: false,
    );
  }

  // One row per lineup group, holding its lineups and their spots as the
  // canvas draws them. A group nobody changed matches its stored row, so
  // it is never written. A new group never takes the id of a row this page
  // has or had, so it never lands on a teammate's group or a deleted one.
  final freshLineupSortIndex = freshSortIndexes(EntitySyncKeyKind.lineup);
  final lineupGroupOf = lineupGroupMemories.lineupGroupOfByPage[pageId] ??= {};
  final lineupRows = cloudLineupRows(
    canvas.lineUpGraph,
    groupOf: lineupGroupOf,
    takenGroupIds: {
      for (final key in [
        ...hydratedBaseKeys,
        ...overlayKeys(),
        ...drawnWorkKeys,
      ])
        if (key.pageId == pageId && key.kind == EntitySyncKeyKind.lineup)
          key.entityId!,
    },
  );
  lineupGroupMemories._rememberLineupGroups(lineupGroupOf, lineupRows.groupOf);
  for (final row in lineupRows.rows) {
    final key = EntitySyncKey.lineup(pageId, row.publicId);
    entities[key] = NormalizedEntity(
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

List<CollabElementEnvelope> collectLocalElementEnvelopes(CanvasOf canvas) {
  final envelopes = <CollabElementEnvelope>[];

  for (final agent in canvas.agents) {
    final payload = Map<String, dynamic>.from(agent.toJson())
      ..putIfAbsent('elementType', () => CollabElementKind.agent.name);
    envelopes.add(
      CollabElementEnvelope(
        publicId: agent.id,
        kind: CollabElementKind.agent,
        payload: payload,
      ),
    );
  }

  for (final ability in canvas.abilities) {
    final payload = Map<String, dynamic>.from(ability.toJson())
      ..putIfAbsent('elementType', () => CollabElementKind.ability.name);
    envelopes.add(
      CollabElementEnvelope(
        publicId: ability.id,
        kind: CollabElementKind.ability,
        payload: payload,
      ),
    );
  }

  for (final drawing in canvas.drawings) {
    final encoded =
        jsonDecode(DrawingProvider.objectToJson([drawing])) as List;
    final payload = Map<String, dynamic>.from(
      (encoded.isEmpty ? <String, dynamic>{} : encoded.first) as Map,
    )..putIfAbsent('elementType', () => CollabElementKind.drawing.name);
    envelopes.add(
      CollabElementEnvelope(
        publicId: drawing.id,
        kind: CollabElementKind.drawing,
        payload: payload,
      ),
    );
  }

  for (final text in canvas.texts) {
    final payload = Map<String, dynamic>.from(text.toJson())
      ..putIfAbsent('elementType', () => CollabElementKind.text.name);
    envelopes.add(
      CollabElementEnvelope(
        publicId: text.id,
        kind: CollabElementKind.text,
        payload: payload,
      ),
    );
  }

  for (final image in canvas.images) {
    final payload = Map<String, dynamic>.from(
      cloudImagePayloadFromPlacedImage(image),
    )..putIfAbsent('elementType', () => CollabElementKind.image.name);
    envelopes.add(
      CollabElementEnvelope(
        publicId: image.id,
        kind: CollabElementKind.image,
        payload: payload,
      ),
    );
  }

  for (final utility in canvas.utilities) {
    final payload = Map<String, dynamic>.from(utility.toJson())
      ..putIfAbsent('elementType', () => CollabElementKind.utility.name);
    envelopes.add(
      CollabElementEnvelope(
        publicId: utility.id,
        kind: CollabElementKind.utility,
        payload: payload,
      ),
    );
  }

  return envelopes;
}

ActivePageOverlayEntry overlayFromDesiredEntity({
  required EntitySyncKey key,
  required NormalizedEntity desired,
  required NormalizedEntity? hydratedBase,
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

StrategyOp? strategyOpFromOverlay({
  required String pageId,
  required ActivePageOverlayEntry overlay,
  required Map<EntitySyncKey, NormalizedEntity> hydratedBaseByEntityKey,
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
          expectedElementRevision: _claimableRevision(
              overlay, baseRevision, hydratedBaseByEntityKey),
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
              hydratedBaseByEntityKey: hydratedBaseByEntityKey,
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
          expectedLineupRevision: _claimableRevision(
              overlay, baseRevision, hydratedBaseByEntityKey),
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
              hydratedBaseByEntityKey: hydratedBaseByEntityKey,
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
  required Map<EntitySyncKey, NormalizedEntity> hydratedBaseByEntityKey,
  required StrategyOp Function(
    FieldMerge? merge,
    int? sortIndex,
    int expectedRevision,
  ) build,
}) {
  final base = hydratedBaseByEntityKey[overlay.entityKey];
  final fields = base == null ||
          base.deleted ||
          !base.mergeable ||
          base.revision != overlay.baseRevision
      ? null
      : lineup
          ? lineupMergeFields(base.payload, payload,
              normalize: withFieldDefaults)
          : elementMergeFields(base.payload, payload,
              normalize: withFieldDefaults);
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
int _claimableRevision(
  ActivePageOverlayEntry overlay,
  int revision,
  Map<EntitySyncKey, NormalizedEntity> hydratedBaseByEntityKey,
) {
  final base = hydratedBaseByEntityKey[overlay.entityKey];
  return base == null ? revision : min(revision, base.claimableRevision);
}

bool opsEquivalent(StrategyOp left, StrategyOp right) {
  return left.kind == right.kind &&
      left.entityType == right.entityType &&
      left.entityPublicId == right.entityPublicId &&
      left.pagePublicId == right.pagePublicId &&
      cloudJsonEquivalent(left.payload, right.payload) &&
      left.sortIndex == right.sortIndex &&
      left.expectedRevision == right.expectedRevision;
}

bool entitiesEquivalent(
  NormalizedEntity? local,
  NormalizedEntity? remote,
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
      payloadsEquivalent(local.payload, remote.payload) &&
      local.sortIndex == remote.sortIndex &&
      local.overlayEntityType == remote.overlayEntityType;
}

bool payloadsEquivalent(Object? left, Object? right) {
  return cloudJsonEquivalent(
    withFieldDefaults(left),
    withFieldDefaults(right),
  );
}

RemotePage? remotePageById({
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

class NormalizedEntity {
  const NormalizedEntity({
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

  NormalizedEntity copyWith({
    Object? payload,
    int? sortIndex,
    int? revision,
    bool? deleted,
    int? receivedOn,
    bool? mergeable,
  }) =>
      NormalizedEntity(
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

  NormalizedEntity withClaimableRevision(int claimable) => NormalizedEntity(
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

class CollabElementEnvelope {
  const CollabElementEnvelope({
    required this.publicId,
    required this.kind,
    required this.payload,
  });

  final String publicId;
  final CollabElementKind kind;
  final Map<String, dynamic> payload;
}

enum CollabElementKind {
  agent,
  ability,
  drawing,
  text,
  image,
  utility;
}
