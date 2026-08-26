import 'dart:convert';

enum StrategyOpKind { add, move, patch, delete, reorder }

enum StrategyOpEntityType { strategy, page, pageContent, element, lineup }

const currentCloudProtocolVersion = 2;
const currentCloudPayloadVersion = 1;

typedef CloudPayload = Map<String, dynamic>;

CloudPayload cloudElementPayload({
  required String kind,
  required Map<String, dynamic> data,
}) {
  return <String, dynamic>{
    'kind': kind,
    'payloadVersion': currentCloudPayloadVersion,
    'data': _normalizeCloudPayloadData(data),
  };
}

CloudPayload cloudLineupGroupPayload(Map<String, dynamic> data) {
  return <String, dynamic>{
    'kind': 'lineupGroup',
    'payloadVersion': currentCloudPayloadVersion,
    'data': _normalizeCloudPayloadData(data),
  };
}

Map<String, dynamic> _normalizeCloudPayloadData(Map<String, dynamic> data) {
  final normalized = jsonDecode(jsonEncode(data));
  if (normalized is Map<String, dynamic>) {
    return normalized;
  }
  if (normalized is Map) {
    return Map<String, dynamic>.from(normalized);
  }
  return <String, dynamic>{};
}

Map<String, dynamic> cloudPayloadData(Object? payload) {
  if (payload is Map<String, dynamic>) {
    final data = payload['data'];
    if (data is Map<String, dynamic>) {
      return _normalizeCloudPayloadData(data);
    }
    if (data is Map) {
      return _normalizeCloudPayloadData(Map<String, dynamic>.from(data));
    }
    return _normalizeCloudPayloadData(payload);
  }
  if (payload is Map) {
    return cloudPayloadData(Map<String, dynamic>.from(payload));
  }
  return <String, dynamic>{};
}

CloudPayload? cloudObjectPayloadOrNull(Object? payload) {
  if (payload == null) {
    return null;
  }
  Object? decoded = payload;
  if (payload is String) {
    try {
      decoded = jsonDecode(payload);
    } catch (_) {
      return null;
    }
  }
  if (decoded is Map<String, dynamic>) {
    return decoded;
  }
  if (decoded is Map) {
    return Map<String, dynamic>.from(decoded);
  }
  return null;
}

CloudPayload cloudObjectPayload(Object? payload) {
  return cloudObjectPayloadOrNull(payload) ?? <String, dynamic>{};
}

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
  });

  final String opId;
  final StrategyOpKind kind;
  final StrategyOpEntityType entityType;
  final String? entityPublicId;
  final String? pagePublicId;
  final Object? payload;
  final int? sortIndex;
  final int? expectedRevision;

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
    };
  }

  factory StrategyOp.fromJson(Map<String, dynamic> json) {
    return StrategyOp(
      opId: json['opId'] as String,
      kind: StrategyOpKind.values.byName(json['kind'] as String),
      entityType:
          StrategyOpEntityType.values.byName(json['entityType'] as String),
      entityPublicId: json['entityPublicId'] as String?,
      pagePublicId: json['pagePublicId'] as String?,
      payload: json['payload'],
      sortIndex: (json['sortIndex'] as num?)?.toInt(),
      expectedRevision: (json['expectedRevision'] as num?)?.toInt(),
    );
  }

  StrategyOp copyWith({
    int? expectedRevision,
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
    this.appliedRevision,
    this.latestRevision,
    this.latestPayload,
  });

  final String opId;
  final String status;
  final String? reason;
  final int? appliedRevision;
  final int? latestRevision;
  final CloudPayload? latestPayload;

  bool get isAck => status == 'ack';

  factory OpAck.fromJson(Map<String, dynamic> json) {
    return OpAck(
      opId: json['opId'] as String,
      status: json['status'] as String,
      reason: json['reason'] as String?,
      appliedRevision: (json['appliedRevision'] as num?)?.toInt(),
      latestRevision: (json['latestRevision'] as num?)?.toInt(),
      latestPayload: json['latestPayload'] == null
          ? null
          : Map<String, dynamic>.from(json['latestPayload'] as Map),
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
  });

  final ConflictResolutionType type;
  final String opId;
  final String? message;
  final Map<String, dynamic>? serverPayload;
  final int? serverRevision;
}

class RemoteStrategyHeader {
  const RemoteStrategyHeader({
    required this.publicId,
    required this.name,
    required this.mapData,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    this.themeProfileId,
    this.themeOverridePalette,
    this.role,
  });

  final String publicId;
  final String name;
  final String mapData;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? themeProfileId;
  final CloudPayload? themeOverridePalette;
  final String? role;

  factory RemoteStrategyHeader.fromJson(Map<String, dynamic> json) {
    return RemoteStrategyHeader(
      publicId: json['publicId'] as String,
      name: json['name'] as String,
      mapData: json['mapData'] as String,
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAt'] as num?)?.toInt() ?? 0,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['updatedAt'] as num?)?.toInt() ?? 0,
      ),
      themeProfileId: json['themeProfileId'] as String?,
      themeOverridePalette:
          cloudObjectPayloadOrNull(json['themeOverridePalette']),
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
    required this.createdAt,
    required this.updatedAt,
  });

  final String publicId;
  final String strategyPublicId;
  final String name;
  final int sortIndex;
  final bool isAttack;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory RemotePage.fromJson(Map<String, dynamic> json) {
    return RemotePage(
      publicId: json['publicId'] as String,
      strategyPublicId: json['strategyPublicId'] as String,
      name: json['name'] as String,
      sortIndex: (json['sortIndex'] as num).toInt(),
      isAttack: json['isAttack'] as bool? ?? true,
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAt'] as num?)?.toInt() ?? 0,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['updatedAt'] as num?)?.toInt() ?? 0,
      ),
    );
  }
}

class RemotePageContent {
  const RemotePageContent({
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    this.settings,
  });

  final CloudPayload? settings;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory RemotePageContent.fromJson(Map<String, dynamic> json) {
    return RemotePageContent(
      settings: cloudObjectPayloadOrNull(json['settings']),
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAt'] as num?)?.toInt() ?? 0,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['updatedAt'] as num?)?.toInt() ?? 0,
      ),
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
  final CloudPayload payload;
  final int sortIndex;
  final int revision;
  final bool deleted;

  Map<String, dynamic> decodedPayload() => cloudPayloadData(payload);

  factory RemoteElement.fromJson(Map<String, dynamic> json) {
    return RemoteElement(
      publicId: json['publicId'] as String,
      strategyPublicId: json['strategyPublicId'] as String,
      pagePublicId: json['pagePublicId'] as String,
      elementType: json['elementType'] as String,
      payload: Map<String, dynamic>.from(json['payload'] as Map),
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
  final CloudPayload payload;
  final int sortIndex;
  final int revision;
  final bool deleted;

  factory RemoteLineup.fromJson(Map<String, dynamic> json) {
    return RemoteLineup(
      publicId: json['publicId'] as String,
      strategyPublicId: json['strategyPublicId'] as String,
      pagePublicId: json['pagePublicId'] as String,
      payload: Map<String, dynamic>.from(json['payload'] as Map),
      sortIndex: (json['sortIndex'] as num?)?.toInt() ?? 0,
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      deleted: json['deleted'] as bool? ?? false,
    );
  }
}

class RemoteImageAsset {
  const RemoteImageAsset({
    required this.publicId,
    required this.fileExtension,
    required this.width,
    required this.height,
    required this.url,
    required this.legacyStoragePath,
    this.provider = 'convex',
    this.uploadStatus = 'active',
    this.mimeType,
    this.byteSize,
    this.uploadedAt,
  });

  final String publicId;
  final String provider;
  final String uploadStatus;
  final String fileExtension;
  final String? mimeType;
  final int? width;
  final int? height;
  final int? byteSize;
  final DateTime? uploadedAt;
  final String? url;
  final String? legacyStoragePath;

  factory RemoteImageAsset.fromJson(Map<String, dynamic> json) {
    return RemoteImageAsset(
      publicId: json['publicId'] as String,
      provider: json['provider'] as String? ?? 'convex',
      uploadStatus: json['uploadStatus'] as String? ?? 'active',
      fileExtension: json['fileExtension'] as String? ?? '',
      mimeType: json['mimeType'] as String?,
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
      byteSize: (json['byteSize'] as num?)?.toInt(),
      uploadedAt: json['uploadedAt'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (json['uploadedAt'] as num).toInt(),
            ),
      url: json['url'] as String?,
      legacyStoragePath: json['legacyStoragePath'] as String?,
    );
  }
}

class RemoteStrategyShell {
  const RemoteStrategyShell({
    required this.header,
    required this.pages,
  });

  final RemoteStrategyHeader header;
  final List<RemotePage> pages;
}

class RemotePageSnapshot {
  const RemotePageSnapshot({
    required this.page,
    required this.content,
    required this.elements,
    required this.lineups,
    required this.assetsById,
  });

  final RemotePage page;
  final RemotePageContent content;
  final List<RemoteElement> elements;
  final List<RemoteLineup> lineups;
  final Map<String, RemoteImageAsset> assetsById;
}

/// The bounded live editor state: one strategy shell and at most one page body.
class RemoteEditorSnapshot {
  const RemoteEditorSnapshot({
    required this.shell,
    required this.activePage,
  });

  final RemoteStrategyShell shell;
  final RemotePageSnapshot? activePage;

  RemoteStrategyHeader get header => shell.header;
  List<RemotePage> get pages => shell.pages;
  Map<String, List<RemoteElement>> get elementsByPage => activePage == null
      ? const <String, List<RemoteElement>>{}
      : <String, List<RemoteElement>>{
          activePage!.page.publicId: activePage!.elements,
        };
  Map<String, List<RemoteLineup>> get lineupsByPage => activePage == null
      ? const <String, List<RemoteLineup>>{}
      : <String, List<RemoteLineup>>{
          activePage!.page.publicId: activePage!.lineups,
        };
  Map<String, RemoteImageAsset> get assetsById =>
      activePage?.assetsById ?? const <String, RemoteImageAsset>{};

  RemoteEditorSnapshot copyWith({
    RemoteStrategyShell? shell,
    RemotePageSnapshot? activePage,
    bool clearActivePage = false,
  }) {
    return RemoteEditorSnapshot(
      shell: shell ?? this.shell,
      activePage: clearActivePage ? null : (activePage ?? this.activePage),
    );
  }
}

class RemoteFullPage {
  const RemoteFullPage({required this.page, required this.content});

  final RemotePage page;
  final RemotePageContent content;
}

/// A one-shot whole-strategy value used only by explicit export/import flows.
class RemoteFullStrategySnapshot {
  const RemoteFullStrategySnapshot({
    required this.header,
    required this.pages,
    required this.elementsByPage,
    required this.lineupsByPage,
    required this.assetsById,
  });

  final RemoteStrategyHeader header;
  final List<RemoteFullPage> pages;
  final Map<String, List<RemoteElement>> elementsByPage;
  final Map<String, List<RemoteLineup>> lineupsByPage;
  final Map<String, RemoteImageAsset> assetsById;

  static Map<String, List<RemoteElement>> groupElementsByPage(
    Iterable<RemoteElement> elements,
  ) {
    final grouped = <String, List<RemoteElement>>{};
    for (final element in elements) {
      (grouped[element.pagePublicId] ??= <RemoteElement>[]).add(element);
    }
    for (final elements in grouped.values) {
      elements.sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    }
    return grouped;
  }

  static Map<String, List<RemoteLineup>> groupLineupsByPage(
    Iterable<RemoteLineup> lineups,
  ) {
    final grouped = <String, List<RemoteLineup>>{};
    for (final lineup in lineups) {
      (grouped[lineup.pagePublicId] ??= <RemoteLineup>[]).add(lineup);
    }
    for (final lineups in grouped.values) {
      lineups.sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    }
    return grouped;
  }
}

class CloudStrategySummary {
  const CloudStrategySummary({
    required this.publicId,
    required this.name,
    required this.mapData,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    this.role,
    this.attackLabel,
  });

  final String publicId;
  final String name;
  final String mapData;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? role;
  final String? attackLabel;

  factory CloudStrategySummary.fromJson(Map<String, dynamic> json) {
    return CloudStrategySummary(
      publicId: json['publicId'] as String,
      name: json['name'] as String,
      mapData: json['mapData'] as String,
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAt'] as num?)?.toInt() ?? 0,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['updatedAt'] as num?)?.toInt() ?? 0,
      ),
      role: json['role'] as String?,
      attackLabel: json['attackLabel'] as String?,
    );
  }
}

class CloudFolderSummary {
  const CloudFolderSummary({
    required this.publicId,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.role,
    this.parentFolderPublicId,
    this.iconId,
    this.iconCodePoint,
    this.iconFontFamily,
    this.iconFontPackage,
    this.color,
    this.customColorValue,
  });

  final String publicId;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? role;
  final String? parentFolderPublicId;
  final int? iconId;
  final int? iconCodePoint;
  final String? iconFontFamily;
  final String? iconFontPackage;
  final String? color;
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
      role: json['role'] as String?,
      parentFolderPublicId: json['parentFolderPublicId'] as String?,
      iconId: (json['iconId'] as num?)?.toInt(),
      iconCodePoint: (json['iconCodePoint'] as num?)?.toInt(),
      iconFontFamily: json['iconFontFamily'] as String?,
      iconFontPackage: json['iconFontPackage'] as String?,
      color: json['color'] as String?,
      customColorValue: (json['customColorValue'] as num?)?.toInt(),
    );
  }
}

class ShareLinkSummary {
  const ShareLinkSummary({
    required this.token,
    required this.role,
    required this.createdAt,
    this.revokedAt,
  });

  final String token;
  final String role;
  final DateTime createdAt;
  final DateTime? revokedAt;

  bool get isRevoked => revokedAt != null;

  factory ShareLinkSummary.fromJson(Map<String, dynamic> json) {
    return ShareLinkSummary(
      token: json['token'] as String,
      role: json['role'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAt'] as num?)?.toInt() ?? 0,
      ),
      revokedAt: json['revokedAt'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (json['revokedAt'] as num).toInt(),
            ),
    );
  }
}
