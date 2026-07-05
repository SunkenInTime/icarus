import 'package:icarus/collab/collab_models.dart';

enum ActivePageOverlayEntityType { pageSettings, element, lineup }

enum EntitySyncKeyKind { strategy, pageSettings, element, lineup }

class EntitySyncKey {
  const EntitySyncKey._({
    required this.kind,
    required this.pageId,
    required this.entityId,
  });

  const EntitySyncKey.pageSettings(String pageId)
      : this._(
          kind: EntitySyncKeyKind.pageSettings,
          pageId: pageId,
          entityId: null,
        );

  const EntitySyncKey.element(String pageId, String elementId)
      : this._(
          kind: EntitySyncKeyKind.element,
          pageId: pageId,
          entityId: elementId,
        );

  const EntitySyncKey.lineup(String pageId, String lineupId)
      : this._(
          kind: EntitySyncKeyKind.lineup,
          pageId: pageId,
          entityId: lineupId,
        );

  const EntitySyncKey.strategy()
      : this._(
          kind: EntitySyncKeyKind.strategy,
          pageId: null,
          entityId: null,
        );

  static String _encodeEntityKeyPart(String value) =>
      Uri.encodeComponent(value);

  static EntitySyncKey? forStrategyOp(StrategyOp op) {
    switch (op.entityType) {
      case StrategyOpEntityType.strategy:
        return const EntitySyncKey.strategy();
      case StrategyOpEntityType.page:
        final pageId = op.entityPublicId ?? op.pagePublicId;
        if (pageId == null) {
          return null;
        }
        return EntitySyncKey.pageSettings(pageId);
      case StrategyOpEntityType.element:
        if (op.pagePublicId == null || op.entityPublicId == null) {
          return null;
        }
        return EntitySyncKey.element(op.pagePublicId!, op.entityPublicId!);
      case StrategyOpEntityType.lineup:
        if (op.pagePublicId == null || op.entityPublicId == null) {
          return null;
        }
        return EntitySyncKey.lineup(op.pagePublicId!, op.entityPublicId!);
    }
  }

  final EntitySyncKeyKind kind;
  final String? pageId;
  final String? entityId;

  ActivePageOverlayEntityType? get overlayType {
    return switch (kind) {
      EntitySyncKeyKind.strategy => null,
      EntitySyncKeyKind.pageSettings =>
        ActivePageOverlayEntityType.pageSettings,
      EntitySyncKeyKind.element => ActivePageOverlayEntityType.element,
      EntitySyncKeyKind.lineup => ActivePageOverlayEntityType.lineup,
    };
  }

  @override
  bool operator ==(Object other) {
    return other is EntitySyncKey &&
        kind == other.kind &&
        pageId == other.pageId &&
        entityId == other.entityId;
  }

  @override
  int get hashCode => Object.hash(kind, pageId, entityId);

  @override
  String toString() {
    final encodedPageId = _encodeEntityKeyPart(pageId ?? '');
    final encodedEntityId = _encodeEntityKeyPart(entityId ?? '');
    return switch (kind) {
      EntitySyncKeyKind.strategy => 'strategy',
      EntitySyncKeyKind.pageSettings => 'page:$encodedPageId:settings',
      EntitySyncKeyKind.element => 'element:$encodedPageId:$encodedEntityId',
      EntitySyncKeyKind.lineup => 'lineup:$encodedPageId:$encodedEntityId',
    };
  }
}

class ActivePageOverlayEntry {
  const ActivePageOverlayEntry({
    required this.entityKey,
    required this.entityType,
    required this.desiredPayload,
    required this.desiredSortIndex,
    required this.deletion,
    required this.baseRevision,
    required this.dirtyAt,
  });

  final EntitySyncKey entityKey;
  final ActivePageOverlayEntityType entityType;
  final Object? desiredPayload;
  final int? desiredSortIndex;
  final bool deletion;
  final int baseRevision;
  final DateTime dirtyAt;

  ActivePageOverlayEntry copyWith({
    Object? desiredPayload,
    int? desiredSortIndex,
    bool? deletion,
    int? baseRevision,
    DateTime? dirtyAt,
  }) {
    return ActivePageOverlayEntry(
      entityKey: entityKey,
      entityType: entityType,
      desiredPayload: desiredPayload ?? this.desiredPayload,
      desiredSortIndex: desiredSortIndex ?? this.desiredSortIndex,
      deletion: deletion ?? this.deletion,
      baseRevision: baseRevision ?? this.baseRevision,
      dirtyAt: dirtyAt ?? this.dirtyAt,
    );
  }
}

class ProjectedPageElement {
  const ProjectedPageElement({
    required this.publicId,
    required this.elementType,
    required this.payload,
    required this.sortIndex,
  });

  final String publicId;
  final String elementType;
  final CloudPayload payload;
  final int sortIndex;
}

class ProjectedPageLineup {
  const ProjectedPageLineup({
    required this.publicId,
    required this.payload,
    required this.sortIndex,
  });

  final String publicId;
  final CloudPayload payload;
  final int sortIndex;
}

class ActivePageProjectedState {
  const ActivePageProjectedState({
    required this.pageId,
    required this.pageName,
    required this.isAttack,
    required this.settingsPayload,
    required this.elements,
    required this.lineups,
  });

  final String pageId;
  final String pageName;
  final bool isAttack;
  final CloudPayload? settingsPayload;
  final List<ProjectedPageElement> elements;
  final List<ProjectedPageLineup> lineups;
}

class QueuedEntityIntent {
  const QueuedEntityIntent({
    required this.entityKey,
    required this.pending,
  });

  final EntitySyncKey entityKey;
  final PendingOp pending;
}

class InFlightEntityIntent {
  const InFlightEntityIntent({
    required this.entityKey,
    required this.pending,
    required this.sentAt,
  });

  final EntitySyncKey entityKey;
  final PendingOp pending;
  final DateTime sentAt;
}

class AckedEntityIntent {
  const AckedEntityIntent({
    required this.entityKey,
    required this.op,
    required this.ack,
  });

  final EntitySyncKey entityKey;
  final StrategyOp op;
  final OpAck ack;
}
