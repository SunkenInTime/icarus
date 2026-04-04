import 'package:icarus/collab/collab_models.dart';

typedef EntitySyncKey = String;

enum ActivePageOverlayEntityType { pageSettings, element, lineup }

EntitySyncKey pageSettingsEntityKey(String pageId) => 'page:$pageId:settings';

EntitySyncKey elementEntityKey(String pageId, String elementId) =>
    'element:$pageId:$elementId';

EntitySyncKey lineupEntityKey(String pageId, String lineupId) =>
    'lineup:$pageId:$lineupId';

String? pageIdForEntityKey(EntitySyncKey entityKey) {
  final parts = entityKey.split(':');
  if (parts.length < 2) {
    return null;
  }
  return parts[1];
}

String? entityIdForEntityKey(EntitySyncKey entityKey) {
  final parts = entityKey.split(':');
  if (parts.length < 3) {
    return null;
  }
  return parts[2];
}

ActivePageOverlayEntityType? overlayEntityTypeForKey(EntitySyncKey entityKey) {
  if (entityKey.startsWith('page:')) {
    return ActivePageOverlayEntityType.pageSettings;
  }
  if (entityKey.startsWith('element:')) {
    return ActivePageOverlayEntityType.element;
  }
  if (entityKey.startsWith('lineup:')) {
    return ActivePageOverlayEntityType.lineup;
  }
  return null;
}

EntitySyncKey? entityKeyForStrategyOp(StrategyOp op) {
  switch (op.entityType) {
    case StrategyOpEntityType.strategy:
      return 'strategy';
    case StrategyOpEntityType.page:
      final pageId = op.entityPublicId ?? op.pagePublicId;
      if (pageId == null) {
        return null;
      }
      return pageSettingsEntityKey(pageId);
    case StrategyOpEntityType.element:
      if (op.pagePublicId == null || op.entityPublicId == null) {
        return null;
      }
      return elementEntityKey(op.pagePublicId!, op.entityPublicId!);
    case StrategyOpEntityType.lineup:
      if (op.pagePublicId == null || op.entityPublicId == null) {
        return null;
      }
      return lineupEntityKey(op.pagePublicId!, op.entityPublicId!);
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
  final String? desiredPayload;
  final int? desiredSortIndex;
  final bool deletion;
  final int baseRevision;
  final DateTime dirtyAt;

  ActivePageOverlayEntry copyWith({
    String? desiredPayload,
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
  final String payload;
  final int sortIndex;
}

class ProjectedPageLineup {
  const ProjectedPageLineup({
    required this.publicId,
    required this.payload,
    required this.sortIndex,
  });

  final String publicId;
  final String payload;
  final int sortIndex;
}

class ActivePageProjectedState {
  const ActivePageProjectedState({
    required this.pageId,
    required this.pageName,
    required this.isAttack,
    required this.settingsJson,
    required this.elements,
    required this.lineups,
  });

  final String pageId;
  final String pageName;
  final bool isAttack;
  final String? settingsJson;
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
