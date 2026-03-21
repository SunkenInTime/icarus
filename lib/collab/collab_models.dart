import 'dart:convert';

enum StrategyOpKind { add, move, patch, delete, reorder }

enum StrategyOpEntityType { strategy, page, element, lineup }

class StrategyOp {
  const StrategyOp({
    required this.opId,
    required this.kind,
    required this.entityType,
    this.entityPublicId,
    this.pagePublicId,
    this.payload,
    this.sortIndex,
    this.expectedRevision,
    this.expectedSequence,
  });

  final String opId;
  final StrategyOpKind kind;
  final StrategyOpEntityType entityType;
  final String? entityPublicId;
  final String? pagePublicId;
  final String? payload;
  final int? sortIndex;
  final int? expectedRevision;
  final int? expectedSequence;

  Map<String, dynamic> toConvexJson() {
    return {
      'opId': opId,
      'kind': kind.name,
      'entityType': entityType.name,
      if (entityPublicId != null) 'entityPublicId': entityPublicId,
      if (pagePublicId != null) 'pagePublicId': pagePublicId,
      if (payload != null) 'payload': payload,
      if (sortIndex != null) 'sortIndex': sortIndex,
      if (expectedRevision != null) 'expectedRevision': expectedRevision,
      if (expectedSequence != null) 'expectedSequence': expectedSequence,
    };
  }

  StrategyOp copyWith({
    int? expectedRevision,
    int? expectedSequence,
  }) {
    return StrategyOp(
      opId: opId,
      kind: kind,
      entityType: entityType,
      entityPublicId: entityPublicId,
      pagePublicId: pagePublicId,
      payload: payload,
      sortIndex: sortIndex,
      expectedRevision: expectedRevision ?? this.expectedRevision,
      expectedSequence: expectedSequence ?? this.expectedSequence,
    );
  }
}

class PendingOp {
  const PendingOp({
    required this.op,
    required this.clientId,
    this.attempts = 0,
    this.lastAttemptAt,
  });

  final StrategyOp op;
  final String clientId;
  final int attempts;
  final DateTime? lastAttemptAt;

  PendingOp incrementAttempt() {
    return PendingOp(
      op: op,
      clientId: clientId,
      attempts: attempts + 1,
      lastAttemptAt: DateTime.now(),
    );
  }
}

class OpAck {
  const OpAck({
    required this.opId,
    required this.status,
    this.reason,
    this.appliedSequence,
    this.latestSequence,
    this.appliedRevision,
    this.latestRevision,
    this.latestPayload,
  });

  final String opId;
  final String status;
  final String? reason;
  final int? appliedSequence;
  final int? latestSequence;
  final int? appliedRevision;
  final int? latestRevision;
  final String? latestPayload;

  bool get isAck => status == 'ack';

  factory OpAck.fromJson(Map<String, dynamic> json) {
    return OpAck(
      opId: json['opId'] as String,
      status: json['status'] as String,
      reason: json['reason'] as String?,
      appliedSequence: (json['appliedSequence'] as num?)?.toInt(),
      latestSequence: (json['latestSequence'] as num?)?.toInt(),
      appliedRevision: (json['appliedRevision'] as num?)?.toInt(),
      latestRevision: (json['latestRevision'] as num?)?.toInt(),
      latestPayload: json['latestPayload'] as String?,
    );
  }
}

enum ConflictResolutionType { rebase, drop, retry }

class ConflictResolution {
  const ConflictResolution({
    required this.type,
    required this.opId,
    this.message,
    this.serverPayload,
    this.serverRevision,
    this.serverSequence,
  });

  final ConflictResolutionType type;
  final String opId;
  final String? message;
  final Map<String, dynamic>? serverPayload;
  final int? serverRevision;
  final int? serverSequence;
}

class RemoteStrategyHeader {
  const RemoteStrategyHeader({
    required this.publicId,
    required this.name,
    required this.mapData,
    required this.sequence,
    required this.createdAt,
    required this.updatedAt,
    this.themeProfileId,
    this.themeOverridePalette,
    this.role,
  });

  final String publicId;
  final String name;
  final String mapData;
  final int sequence;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? themeProfileId;
  final String? themeOverridePalette;
  final String? role;

  factory RemoteStrategyHeader.fromJson(Map<String, dynamic> json) {
    return RemoteStrategyHeader(
      publicId: json['publicId'] as String,
      name: json['name'] as String,
      mapData: json['mapData'] as String,
      sequence: (json['sequence'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAt'] as num?)?.toInt() ?? 0,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['updatedAt'] as num?)?.toInt() ?? 0,
      ),
      themeProfileId: json['themeProfileId'] as String?,
      themeOverridePalette: json['themeOverridePalette'] as String?,
      role: json['role'] as String?,
    );
  }
}

class RemotePage {
  const RemotePage({
    required this.publicId,
    required this.strategyPublicId,
    required this.name,
    required this.sortIndex,
    required this.isAttack,
    required this.revision,
    this.settings,
  });

  final String publicId;
  final String strategyPublicId;
  final String name;
  final int sortIndex;
  final bool isAttack;
  final int revision;
  final String? settings;

  factory RemotePage.fromJson(Map<String, dynamic> json) {
    return RemotePage(
      publicId: json['publicId'] as String,
      strategyPublicId: json['strategyPublicId'] as String,
      name: json['name'] as String,
      sortIndex: (json['sortIndex'] as num).toInt(),
      isAttack: json['isAttack'] as bool? ?? true,
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      settings: json['settings'] as String?,
    );
  }
}

class RemoteElement {
  const RemoteElement({
    required this.publicId,
    required this.strategyPublicId,
    required this.pagePublicId,
    required this.elementType,
    required this.payload,
    required this.sortIndex,
    required this.revision,
    required this.deleted,
  });

  final String publicId;
  final String strategyPublicId;
  final String pagePublicId;
  final String elementType;
  final String payload;
  final int sortIndex;
  final int revision;
  final bool deleted;

  Map<String, dynamic> decodedPayload() {
    try {
      final parsed = jsonDecode(payload);
      if (parsed is Map<String, dynamic>) {
        return parsed;
      }
    } catch (_) {}
    return <String, dynamic>{};
  }

  factory RemoteElement.fromJson(Map<String, dynamic> json) {
    return RemoteElement(
      publicId: json['publicId'] as String,
      strategyPublicId: json['strategyPublicId'] as String,
      pagePublicId: json['pagePublicId'] as String,
      elementType: json['elementType'] as String,
      payload: json['payload'] as String,
      sortIndex: (json['sortIndex'] as num?)?.toInt() ?? 0,
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      deleted: json['deleted'] as bool? ?? false,
    );
  }
}

class RemoteLineup {
  const RemoteLineup({
    required this.publicId,
    required this.strategyPublicId,
    required this.pagePublicId,
    required this.payload,
    required this.sortIndex,
    required this.revision,
    required this.deleted,
  });

  final String publicId;
  final String strategyPublicId;
  final String pagePublicId;
  final String payload;
  final int sortIndex;
  final int revision;
  final bool deleted;

  factory RemoteLineup.fromJson(Map<String, dynamic> json) {
    return RemoteLineup(
      publicId: json['publicId'] as String,
      strategyPublicId: json['strategyPublicId'] as String,
      pagePublicId: json['pagePublicId'] as String,
      payload: json['payload'] as String,
      sortIndex: (json['sortIndex'] as num?)?.toInt() ?? 0,
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      deleted: json['deleted'] as bool? ?? false,
    );
  }
}

class RemoteStrategySnapshot {
  const RemoteStrategySnapshot({
    required this.header,
    required this.pages,
    required this.elementsByPage,
    required this.lineupsByPage,
  });

  final RemoteStrategyHeader header;
  final List<RemotePage> pages;
  final Map<String, List<RemoteElement>> elementsByPage;
  final Map<String, List<RemoteLineup>> lineupsByPage;
}

class CloudStrategySummary {
  const CloudStrategySummary({
    required this.publicId,
    required this.name,
    required this.mapData,
    required this.sequence,
    required this.createdAt,
    required this.updatedAt,
    this.role,
  });

  final String publicId;
  final String name;
  final String mapData;
  final int sequence;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? role;

  factory CloudStrategySummary.fromJson(Map<String, dynamic> json) {
    return CloudStrategySummary(
      publicId: json['publicId'] as String,
      name: json['name'] as String,
      mapData: json['mapData'] as String,
      sequence: (json['sequence'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAt'] as num?)?.toInt() ?? 0,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['updatedAt'] as num?)?.toInt() ?? 0,
      ),
      role: json['role'] as String?,
    );
  }
}

class CloudFolderSummary {
  const CloudFolderSummary({
    required this.publicId,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.parentFolderPublicId,
    this.iconIndex,
    this.colorKey,
    this.customColorValue,
  });

  final String publicId;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? parentFolderPublicId;
  final int? iconIndex;
  final String? colorKey;
  final int? customColorValue;

  factory CloudFolderSummary.fromJson(Map<String, dynamic> json) {
    return CloudFolderSummary(
      publicId: json['publicId'] as String,
      name: json['name'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAt'] as num?)?.toInt() ?? 0,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['updatedAt'] as num?)?.toInt() ?? 0,
      ),
      parentFolderPublicId: json['parentFolderPublicId'] as String?,
      iconIndex: (json['iconIndex'] as num?)?.toInt(),
      colorKey: json['colorKey'] as String?,
      customColorValue: (json['customColorValue'] as num?)?.toInt(),
    );
  }
}
