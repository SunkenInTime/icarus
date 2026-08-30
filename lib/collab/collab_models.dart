import 'dart:convert';

const currentCloudProtocolVersion = 3;
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

enum StrategyOpType {
  strategyPatch('strategy.patch'),
  pageAdd('page.add'),
  pagePatch('page.patch'),
  pageDelete('page.delete'),
  pageReorder('page.reorder'),
  pageContentPatch('pageContent.patch'),
  elementAdd('element.add'),
  elementPatch('element.patch'),
  elementDelete('element.delete'),
  elementReorder('element.reorder'),
  lineupAdd('lineup.add'),
  lineupPatch('lineup.patch'),
  lineupDelete('lineup.delete'),
  lineupReorder('lineup.reorder');

  const StrategyOpType(this.wireName);

  final String wireName;

  static StrategyOpType fromWireName(String value) =>
      values.firstWhere((type) => type.wireName == value);
}

enum StrategyOpKind { add, patch, delete, reorder }

enum StrategyOpEntityType { strategy, page, pageContent, element, lineup }

sealed class StrategyOp {
  const StrategyOp();

  String get opId;
  StrategyOpType get type;
  StrategyOpKind get kind => switch (type) {
        StrategyOpType.strategyPatch ||
        StrategyOpType.pagePatch ||
        StrategyOpType.pageContentPatch ||
        StrategyOpType.elementPatch ||
        StrategyOpType.lineupPatch =>
          StrategyOpKind.patch,
        StrategyOpType.pageAdd ||
        StrategyOpType.elementAdd ||
        StrategyOpType.lineupAdd =>
          StrategyOpKind.add,
        StrategyOpType.pageDelete ||
        StrategyOpType.elementDelete ||
        StrategyOpType.lineupDelete =>
          StrategyOpKind.delete,
        StrategyOpType.pageReorder ||
        StrategyOpType.elementReorder ||
        StrategyOpType.lineupReorder =>
          StrategyOpKind.reorder,
      };
  StrategyOpEntityType get entityType => switch (type) {
        StrategyOpType.strategyPatch => StrategyOpEntityType.strategy,
        StrategyOpType.pageAdd ||
        StrategyOpType.pagePatch ||
        StrategyOpType.pageDelete ||
        StrategyOpType.pageReorder =>
          StrategyOpEntityType.page,
        StrategyOpType.pageContentPatch => StrategyOpEntityType.pageContent,
        StrategyOpType.elementAdd ||
        StrategyOpType.elementPatch ||
        StrategyOpType.elementDelete ||
        StrategyOpType.elementReorder =>
          StrategyOpEntityType.element,
        StrategyOpType.lineupAdd ||
        StrategyOpType.lineupPatch ||
        StrategyOpType.lineupDelete ||
        StrategyOpType.lineupReorder =>
          StrategyOpEntityType.lineup,
      };

  String? get entityPublicId => switch (this) {
        StrategyPatchOp() => null,
        PageAddOp(:final pagePublicId) ||
        PagePatchOp(:final pagePublicId) ||
        PageDeleteOp(:final pagePublicId) ||
        PageReorderOp(:final pagePublicId) ||
        PageContentPatchOp(:final pagePublicId) =>
          pagePublicId,
        ElementAddOp(:final elementPublicId) ||
        ElementPatchOp(:final elementPublicId) ||
        ElementDeleteOp(:final elementPublicId) ||
        ElementReorderOp(:final elementPublicId) =>
          elementPublicId,
        LineupAddOp(:final lineupPublicId) ||
        LineupPatchOp(:final lineupPublicId) ||
        LineupDeleteOp(:final lineupPublicId) ||
        LineupReorderOp(:final lineupPublicId) =>
          lineupPublicId,
      };

  String? get pagePublicId => switch (this) {
        PageAddOp(:final pagePublicId) ||
        PagePatchOp(:final pagePublicId) ||
        PageDeleteOp(:final pagePublicId) ||
        PageReorderOp(:final pagePublicId) ||
        PageContentPatchOp(:final pagePublicId) ||
        ElementAddOp(:final pagePublicId) ||
        LineupAddOp(:final pagePublicId) =>
          pagePublicId,
        ElementPatchOp(:final pagePublicId) ||
        LineupPatchOp(:final pagePublicId) =>
          pagePublicId,
        ElementDeleteOp(:final pagePublicId) ||
        ElementReorderOp(:final pagePublicId) ||
        LineupDeleteOp(:final pagePublicId) ||
        LineupReorderOp(:final pagePublicId) =>
          pagePublicId,
        StrategyPatchOp() => null,
      };

  Object? get payload => switch (this) {
        StrategyPatchOp(:final payload) ||
        PageAddOp(:final payload) ||
        PagePatchOp(:final payload) ||
        ElementAddOp(:final payload) ||
        LineupAddOp(:final payload) =>
          payload,
        ElementPatchOp(:final payload) ||
        LineupPatchOp(:final payload) =>
          payload,
        PageContentPatchOp(:final settings) => {'settings': settings},
        PageDeleteOp() ||
        PageReorderOp() ||
        ElementDeleteOp() ||
        ElementReorderOp() ||
        LineupDeleteOp() ||
        LineupReorderOp() =>
          null,
      };

  int? get sortIndex => switch (this) {
        PageAddOp(:final sortIndex) ||
        PageReorderOp(:final sortIndex) ||
        ElementAddOp(:final sortIndex) ||
        ElementReorderOp(:final sortIndex) ||
        LineupAddOp(:final sortIndex) ||
        LineupReorderOp(:final sortIndex) =>
          sortIndex,
        ElementPatchOp(:final sortIndex) ||
        LineupPatchOp(:final sortIndex) =>
          sortIndex,
        StrategyPatchOp() ||
        PagePatchOp() ||
        PageDeleteOp() ||
        PageContentPatchOp() ||
        ElementDeleteOp() ||
        LineupDeleteOp() =>
          null,
      };

  int? get expectedRevision => switch (this) {
        StrategyPatchOp(:final expectedStrategyRevision) ||
        PageAddOp(:final expectedStrategyRevision) ||
        PageDeleteOp(:final expectedStrategyRevision) ||
        PageReorderOp(:final expectedStrategyRevision) =>
          expectedStrategyRevision,
        PagePatchOp(:final expectedPageRevision) => expectedPageRevision,
        PageContentPatchOp(:final expectedPageContentRevision) =>
          expectedPageContentRevision,
        ElementAddOp(:final expectedElementRevision) => expectedElementRevision,
        ElementPatchOp(:final expectedElementRevision) ||
        ElementDeleteOp(:final expectedElementRevision) ||
        ElementReorderOp(:final expectedElementRevision) =>
          expectedElementRevision,
        LineupAddOp(:final expectedLineupRevision) => expectedLineupRevision,
        LineupPatchOp(:final expectedLineupRevision) ||
        LineupDeleteOp(:final expectedLineupRevision) ||
        LineupReorderOp(:final expectedLineupRevision) =>
          expectedLineupRevision,
      };

  Map<String, dynamic> toConvexJson() => switch (this) {
        StrategyPatchOp() => {
            'opId': opId,
            'type': type.wireName,
            'payload': payload,
            'expectedStrategyRevision': expectedRevision,
          },
        PageAddOp() => {
            'opId': opId,
            'type': type.wireName,
            'pagePublicId': pagePublicId,
            'payload': payload,
            'sortIndex': sortIndex,
            'expectedStrategyRevision': expectedRevision,
          },
        PagePatchOp() => {
            'opId': opId,
            'type': type.wireName,
            'pagePublicId': pagePublicId,
            'payload': payload,
            'expectedPageRevision': expectedRevision,
          },
        PageDeleteOp() => {
            'opId': opId,
            'type': type.wireName,
            'pagePublicId': pagePublicId,
            'expectedStrategyRevision': expectedRevision,
          },
        PageReorderOp() => {
            'opId': opId,
            'type': type.wireName,
            'pagePublicId': pagePublicId,
            'sortIndex': sortIndex,
            'expectedStrategyRevision': expectedRevision,
          },
        PageContentPatchOp(:final settings) => {
            'opId': opId,
            'type': type.wireName,
            'pagePublicId': pagePublicId,
            'settings': settings,
            'expectedPageContentRevision': expectedRevision,
          },
        ElementAddOp() => {
            'opId': opId,
            'type': type.wireName,
            'elementPublicId': entityPublicId,
            'pagePublicId': pagePublicId,
            'payload': payload,
            'sortIndex': sortIndex,
            if (expectedRevision != null)
              'expectedElementRevision': expectedRevision,
          },
        ElementPatchOp() => {
            'opId': opId,
            'type': type.wireName,
            'elementPublicId': entityPublicId,
            if (pagePublicId != null) 'pagePublicId': pagePublicId,
            if (payload != null) 'payload': payload,
            if (sortIndex != null) 'sortIndex': sortIndex,
            'expectedElementRevision': expectedRevision,
          },
        ElementDeleteOp() => {
            'opId': opId,
            'type': type.wireName,
            'elementPublicId': entityPublicId,
            'pagePublicId': pagePublicId,
            'expectedElementRevision': expectedRevision,
          },
        ElementReorderOp() => {
            'opId': opId,
            'type': type.wireName,
            'elementPublicId': entityPublicId,
            'pagePublicId': pagePublicId,
            'sortIndex': sortIndex,
            'expectedElementRevision': expectedRevision,
          },
        LineupAddOp() => {
            'opId': opId,
            'type': type.wireName,
            'lineupPublicId': entityPublicId,
            'pagePublicId': pagePublicId,
            'payload': payload,
            'sortIndex': sortIndex,
            if (expectedRevision != null)
              'expectedLineupRevision': expectedRevision,
          },
        LineupPatchOp() => {
            'opId': opId,
            'type': type.wireName,
            'lineupPublicId': entityPublicId,
            if (pagePublicId != null) 'pagePublicId': pagePublicId,
            if (payload != null) 'payload': payload,
            if (sortIndex != null) 'sortIndex': sortIndex,
            'expectedLineupRevision': expectedRevision,
          },
        LineupDeleteOp() => {
            'opId': opId,
            'type': type.wireName,
            'lineupPublicId': entityPublicId,
            'pagePublicId': pagePublicId,
            'expectedLineupRevision': expectedRevision,
          },
        LineupReorderOp() => {
            'opId': opId,
            'type': type.wireName,
            'lineupPublicId': entityPublicId,
            'pagePublicId': pagePublicId,
            'sortIndex': sortIndex,
            'expectedLineupRevision': expectedRevision,
          },
      };

  factory StrategyOp.fromJson(Map<String, dynamic> json) {
    final opId = json['opId'] as String;
    return switch (StrategyOpType.fromWireName(json['type'] as String)) {
      StrategyOpType.strategyPatch => StrategyPatchOp(
          opId: opId,
          payload: _requiredMap(json['payload'], 'payload'),
          expectedStrategyRevision:
              _requiredInt(json['expectedStrategyRevision']),
        ),
      StrategyOpType.pageAdd => PageAddOp(
          opId: opId,
          pagePublicId: json['pagePublicId'] as String,
          payload: _requiredMap(json['payload'], 'payload'),
          sortIndex: _requiredInt(json['sortIndex']),
          expectedStrategyRevision:
              _requiredInt(json['expectedStrategyRevision']),
        ),
      StrategyOpType.pagePatch => PagePatchOp(
          opId: opId,
          pagePublicId: json['pagePublicId'] as String,
          payload: _requiredMap(json['payload'], 'payload'),
          expectedPageRevision: _requiredInt(json['expectedPageRevision']),
        ),
      StrategyOpType.pageDelete => PageDeleteOp(
          opId: opId,
          pagePublicId: json['pagePublicId'] as String,
          expectedStrategyRevision:
              _requiredInt(json['expectedStrategyRevision']),
        ),
      StrategyOpType.pageReorder => PageReorderOp(
          opId: opId,
          pagePublicId: json['pagePublicId'] as String,
          sortIndex: _requiredInt(json['sortIndex']),
          expectedStrategyRevision:
              _requiredInt(json['expectedStrategyRevision']),
        ),
      StrategyOpType.pageContentPatch => PageContentPatchOp(
          opId: opId,
          pagePublicId: json['pagePublicId'] as String,
          settings: _requiredMap(json['settings'], 'settings'),
          expectedPageContentRevision:
              _requiredInt(json['expectedPageContentRevision']),
        ),
      StrategyOpType.elementAdd => ElementAddOp(
          opId: opId,
          elementPublicId: json['elementPublicId'] as String,
          pagePublicId: json['pagePublicId'] as String,
          payload: _requiredMap(json['payload'], 'payload'),
          sortIndex: _requiredInt(json['sortIndex']),
          expectedElementRevision:
              (json['expectedElementRevision'] as num?)?.toInt(),
        ),
      StrategyOpType.elementPatch => ElementPatchOp(
          opId: opId,
          elementPublicId: json['elementPublicId'] as String,
          pagePublicId: json['pagePublicId'] as String?,
          payload: _optionalMap(json['payload']),
          sortIndex: (json['sortIndex'] as num?)?.toInt(),
          expectedElementRevision:
              _requiredInt(json['expectedElementRevision']),
        ),
      StrategyOpType.elementDelete => ElementDeleteOp(
          opId: opId,
          elementPublicId: json['elementPublicId'] as String,
          pagePublicId: json['pagePublicId'] as String,
          expectedElementRevision:
              _requiredInt(json['expectedElementRevision']),
        ),
      StrategyOpType.elementReorder => ElementReorderOp(
          opId: opId,
          elementPublicId: json['elementPublicId'] as String,
          pagePublicId: json['pagePublicId'] as String,
          sortIndex: _requiredInt(json['sortIndex']),
          expectedElementRevision:
              _requiredInt(json['expectedElementRevision']),
        ),
      StrategyOpType.lineupAdd => LineupAddOp(
          opId: opId,
          lineupPublicId: json['lineupPublicId'] as String,
          pagePublicId: json['pagePublicId'] as String,
          payload: _requiredMap(json['payload'], 'payload'),
          sortIndex: _requiredInt(json['sortIndex']),
          expectedLineupRevision:
              (json['expectedLineupRevision'] as num?)?.toInt(),
        ),
      StrategyOpType.lineupPatch => LineupPatchOp(
          opId: opId,
          lineupPublicId: json['lineupPublicId'] as String,
          pagePublicId: json['pagePublicId'] as String?,
          payload: _optionalMap(json['payload']),
          sortIndex: (json['sortIndex'] as num?)?.toInt(),
          expectedLineupRevision: _requiredInt(json['expectedLineupRevision']),
        ),
      StrategyOpType.lineupDelete => LineupDeleteOp(
          opId: opId,
          lineupPublicId: json['lineupPublicId'] as String,
          pagePublicId: json['pagePublicId'] as String,
          expectedLineupRevision: _requiredInt(json['expectedLineupRevision']),
        ),
      StrategyOpType.lineupReorder => LineupReorderOp(
          opId: opId,
          lineupPublicId: json['lineupPublicId'] as String,
          pagePublicId: json['pagePublicId'] as String,
          sortIndex: _requiredInt(json['sortIndex']),
          expectedLineupRevision: _requiredInt(json['expectedLineupRevision']),
        ),
    };
  }

  StrategyOp withOpId(String value) => switch (this) {
        StrategyPatchOp(:final payload, :final expectedStrategyRevision) =>
          StrategyPatchOp(
            opId: value,
            payload: payload,
            expectedStrategyRevision: expectedStrategyRevision,
          ),
        PageAddOp(
          :final pagePublicId,
          :final payload,
          :final sortIndex,
          :final expectedStrategyRevision,
        ) =>
          PageAddOp(
            opId: value,
            pagePublicId: pagePublicId,
            payload: payload,
            sortIndex: sortIndex,
            expectedStrategyRevision: expectedStrategyRevision,
          ),
        PagePatchOp(
          :final pagePublicId,
          :final payload,
          :final expectedPageRevision,
        ) =>
          PagePatchOp(
            opId: value,
            pagePublicId: pagePublicId,
            payload: payload,
            expectedPageRevision: expectedPageRevision,
          ),
        PageDeleteOp(:final pagePublicId, :final expectedStrategyRevision) =>
          PageDeleteOp(
            opId: value,
            pagePublicId: pagePublicId,
            expectedStrategyRevision: expectedStrategyRevision,
          ),
        PageReorderOp(
          :final pagePublicId,
          :final sortIndex,
          :final expectedStrategyRevision,
        ) =>
          PageReorderOp(
            opId: value,
            pagePublicId: pagePublicId,
            sortIndex: sortIndex,
            expectedStrategyRevision: expectedStrategyRevision,
          ),
        PageContentPatchOp(
          :final pagePublicId,
          :final settings,
          :final expectedPageContentRevision,
        ) =>
          PageContentPatchOp(
            opId: value,
            pagePublicId: pagePublicId,
            settings: settings,
            expectedPageContentRevision: expectedPageContentRevision,
          ),
        ElementAddOp(
          :final elementPublicId,
          :final pagePublicId,
          :final payload,
          :final sortIndex,
          :final expectedElementRevision,
        ) =>
          ElementAddOp(
            opId: value,
            elementPublicId: elementPublicId,
            pagePublicId: pagePublicId,
            payload: payload,
            sortIndex: sortIndex,
            expectedElementRevision: expectedElementRevision,
          ),
        ElementPatchOp(
          :final elementPublicId,
          :final pagePublicId,
          :final payload,
          :final sortIndex,
          :final expectedElementRevision,
        ) =>
          ElementPatchOp(
            opId: value,
            elementPublicId: elementPublicId,
            pagePublicId: pagePublicId,
            payload: payload,
            sortIndex: sortIndex,
            expectedElementRevision: expectedElementRevision,
          ),
        ElementDeleteOp(
          :final elementPublicId,
          :final pagePublicId,
          :final expectedElementRevision,
        ) =>
          ElementDeleteOp(
            opId: value,
            elementPublicId: elementPublicId,
            pagePublicId: pagePublicId,
            expectedElementRevision: expectedElementRevision,
          ),
        ElementReorderOp(
          :final elementPublicId,
          :final pagePublicId,
          :final sortIndex,
          :final expectedElementRevision,
        ) =>
          ElementReorderOp(
            opId: value,
            elementPublicId: elementPublicId,
            pagePublicId: pagePublicId,
            sortIndex: sortIndex,
            expectedElementRevision: expectedElementRevision,
          ),
        LineupAddOp(
          :final lineupPublicId,
          :final pagePublicId,
          :final payload,
          :final sortIndex,
          :final expectedLineupRevision,
        ) =>
          LineupAddOp(
            opId: value,
            lineupPublicId: lineupPublicId,
            pagePublicId: pagePublicId,
            payload: payload,
            sortIndex: sortIndex,
            expectedLineupRevision: expectedLineupRevision,
          ),
        LineupPatchOp(
          :final lineupPublicId,
          :final pagePublicId,
          :final payload,
          :final sortIndex,
          :final expectedLineupRevision,
        ) =>
          LineupPatchOp(
            opId: value,
            lineupPublicId: lineupPublicId,
            pagePublicId: pagePublicId,
            payload: payload,
            sortIndex: sortIndex,
            expectedLineupRevision: expectedLineupRevision,
          ),
        LineupDeleteOp(
          :final lineupPublicId,
          :final pagePublicId,
          :final expectedLineupRevision,
        ) =>
          LineupDeleteOp(
            opId: value,
            lineupPublicId: lineupPublicId,
            pagePublicId: pagePublicId,
            expectedLineupRevision: expectedLineupRevision,
          ),
        LineupReorderOp(
          :final lineupPublicId,
          :final pagePublicId,
          :final sortIndex,
          :final expectedLineupRevision,
        ) =>
          LineupReorderOp(
            opId: value,
            lineupPublicId: lineupPublicId,
            pagePublicId: pagePublicId,
            sortIndex: sortIndex,
            expectedLineupRevision: expectedLineupRevision,
          ),
      };
}

final class StrategyPatchOp extends StrategyOp {
  const StrategyPatchOp({
    required this.opId,
    required this.payload,
    required this.expectedStrategyRevision,
  });
  @override
  final String opId;
  @override
  final CloudPayload payload;
  final int expectedStrategyRevision;
  @override
  StrategyOpType get type => StrategyOpType.strategyPatch;
}

final class PageAddOp extends StrategyOp {
  const PageAddOp({
    required this.opId,
    required this.pagePublicId,
    required this.payload,
    required this.sortIndex,
    required this.expectedStrategyRevision,
  });
  @override
  final String opId;
  @override
  final String pagePublicId;
  @override
  final CloudPayload payload;
  @override
  final int sortIndex;
  final int expectedStrategyRevision;
  @override
  StrategyOpType get type => StrategyOpType.pageAdd;
}

final class PagePatchOp extends StrategyOp {
  const PagePatchOp({
    required this.opId,
    required this.pagePublicId,
    required this.payload,
    required this.expectedPageRevision,
  });
  @override
  final String opId;
  @override
  final String pagePublicId;
  @override
  final CloudPayload payload;
  final int expectedPageRevision;
  @override
  StrategyOpType get type => StrategyOpType.pagePatch;
}

final class PageDeleteOp extends StrategyOp {
  const PageDeleteOp({
    required this.opId,
    required this.pagePublicId,
    required this.expectedStrategyRevision,
  });
  @override
  final String opId;
  @override
  final String pagePublicId;
  final int expectedStrategyRevision;
  @override
  StrategyOpType get type => StrategyOpType.pageDelete;
}

final class PageReorderOp extends StrategyOp {
  const PageReorderOp({
    required this.opId,
    required this.pagePublicId,
    required this.sortIndex,
    required this.expectedStrategyRevision,
  });
  @override
  final String opId;
  @override
  final String pagePublicId;
  @override
  final int sortIndex;
  final int expectedStrategyRevision;
  @override
  StrategyOpType get type => StrategyOpType.pageReorder;
}

final class PageContentPatchOp extends StrategyOp {
  const PageContentPatchOp({
    required this.opId,
    required this.pagePublicId,
    required this.settings,
    required this.expectedPageContentRevision,
  });
  @override
  final String opId;
  @override
  final String pagePublicId;
  final CloudPayload settings;
  final int expectedPageContentRevision;
  @override
  StrategyOpType get type => StrategyOpType.pageContentPatch;
}

final class ElementAddOp extends StrategyOp {
  const ElementAddOp({
    required this.opId,
    required this.elementPublicId,
    required this.pagePublicId,
    required this.payload,
    required this.sortIndex,
    this.expectedElementRevision,
  });
  @override
  final String opId;
  final String elementPublicId;
  @override
  final String pagePublicId;
  @override
  final CloudPayload payload;
  @override
  final int sortIndex;
  final int? expectedElementRevision;
  @override
  StrategyOpType get type => StrategyOpType.elementAdd;
}

final class ElementPatchOp extends StrategyOp {
  const ElementPatchOp({
    required this.opId,
    required this.elementPublicId,
    required this.expectedElementRevision,
    this.pagePublicId,
    this.payload,
    this.sortIndex,
  });
  @override
  final String opId;
  final String elementPublicId;
  @override
  final String? pagePublicId;
  @override
  final CloudPayload? payload;
  @override
  final int? sortIndex;
  final int expectedElementRevision;
  @override
  StrategyOpType get type => StrategyOpType.elementPatch;
}

final class ElementDeleteOp extends StrategyOp {
  const ElementDeleteOp({
    required this.opId,
    required this.elementPublicId,
    required this.pagePublicId,
    required this.expectedElementRevision,
  });
  @override
  final String opId;
  final String elementPublicId;
  @override
  final String pagePublicId;
  final int expectedElementRevision;
  @override
  StrategyOpType get type => StrategyOpType.elementDelete;
}

final class ElementReorderOp extends StrategyOp {
  const ElementReorderOp({
    required this.opId,
    required this.elementPublicId,
    required this.pagePublicId,
    required this.sortIndex,
    required this.expectedElementRevision,
  });
  @override
  final String opId;
  final String elementPublicId;
  @override
  final String pagePublicId;
  @override
  final int sortIndex;
  final int expectedElementRevision;
  @override
  StrategyOpType get type => StrategyOpType.elementReorder;
}

final class LineupAddOp extends StrategyOp {
  const LineupAddOp({
    required this.opId,
    required this.lineupPublicId,
    required this.pagePublicId,
    required this.payload,
    required this.sortIndex,
    this.expectedLineupRevision,
  });
  @override
  final String opId;
  final String lineupPublicId;
  @override
  final String pagePublicId;
  @override
  final CloudPayload payload;
  @override
  final int sortIndex;
  final int? expectedLineupRevision;
  @override
  StrategyOpType get type => StrategyOpType.lineupAdd;
}

final class LineupPatchOp extends StrategyOp {
  const LineupPatchOp({
    required this.opId,
    required this.lineupPublicId,
    required this.expectedLineupRevision,
    this.pagePublicId,
    this.payload,
    this.sortIndex,
  });
  @override
  final String opId;
  final String lineupPublicId;
  @override
  final String? pagePublicId;
  @override
  final CloudPayload? payload;
  @override
  final int? sortIndex;
  final int expectedLineupRevision;
  @override
  StrategyOpType get type => StrategyOpType.lineupPatch;
}

final class LineupDeleteOp extends StrategyOp {
  const LineupDeleteOp({
    required this.opId,
    required this.lineupPublicId,
    required this.pagePublicId,
    required this.expectedLineupRevision,
  });
  @override
  final String opId;
  final String lineupPublicId;
  @override
  final String pagePublicId;
  final int expectedLineupRevision;
  @override
  StrategyOpType get type => StrategyOpType.lineupDelete;
}

final class LineupReorderOp extends StrategyOp {
  const LineupReorderOp({
    required this.opId,
    required this.lineupPublicId,
    required this.pagePublicId,
    required this.sortIndex,
    required this.expectedLineupRevision,
  });
  @override
  final String opId;
  final String lineupPublicId;
  @override
  final String pagePublicId;
  @override
  final int sortIndex;
  final int expectedLineupRevision;
  @override
  StrategyOpType get type => StrategyOpType.lineupReorder;
}

Map<String, dynamic> _requiredMap(Object? value, String field) {
  final map = _optionalMap(value);
  if (map == null) throw FormatException('Op $field must be an object');
  return map;
}

Map<String, dynamic>? _optionalMap(Object? value) {
  if (value == null) return null;
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw const FormatException('Op value must be an object');
}

int _requiredInt(Object? value) {
  if (value is num) return value.toInt();
  throw const FormatException('Op revision or index must be a number');
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

enum OpRejectionReason {
  alreadyExists('already_exists'),
  elementStrategyMismatch('element_strategy_mismatch'),
  lineupStrategyMismatch('lineup_strategy_mismatch'),
  missingExpectedRevision('missing_expected_revision'),
  notFound('not_found'),
  pageStrategyMismatch('page_strategy_mismatch'),
  revisionMismatch('revision_mismatch');

  const OpRejectionReason(this.wireName);
  final String wireName;

  static OpRejectionReason fromWireName(String value) =>
      values.firstWhere((reason) => reason.wireName == value);
}

sealed class CurrentOpSnapshot {
  const CurrentOpSnapshot({required this.revision, required this.value});
  final int revision;
  final CloudPayload value;

  factory CurrentOpSnapshot.fromJson(Map<String, dynamic> json) {
    final revision = _requiredInt(json['revision']);
    final value = _requiredMap(json['value'], 'current.value');
    return switch (json['type']) {
      'strategy' => StrategyCurrentSnapshot(revision: revision, value: value),
      'page' => PageCurrentSnapshot(revision: revision, value: value),
      'pageContent' =>
        PageContentCurrentSnapshot(revision: revision, value: value),
      'element' => ElementCurrentSnapshot(revision: revision, value: value),
      'lineup' => LineupCurrentSnapshot(revision: revision, value: value),
      final Object? type => throw FormatException(
          'Unknown current op snapshot type: $type',
        ),
    };
  }
}

final class StrategyCurrentSnapshot extends CurrentOpSnapshot {
  const StrategyCurrentSnapshot(
      {required super.revision, required super.value});
}

final class PageCurrentSnapshot extends CurrentOpSnapshot {
  const PageCurrentSnapshot({required super.revision, required super.value});
}

final class PageContentCurrentSnapshot extends CurrentOpSnapshot {
  const PageContentCurrentSnapshot({
    required super.revision,
    required super.value,
  });
}

final class ElementCurrentSnapshot extends CurrentOpSnapshot {
  const ElementCurrentSnapshot({required super.revision, required super.value});
}

final class LineupCurrentSnapshot extends CurrentOpSnapshot {
  const LineupCurrentSnapshot({required super.revision, required super.value});
}

sealed class OpAck {
  const OpAck();

  String get opId;
  String get status => switch (this) {
        AppliedOpAck() => 'applied',
        NoopOpAck() => 'noop',
        RejectedOpAck() => 'rejected',
        FailedOpAck() => 'failed',
      };
  bool get isAck => this is AppliedOpAck || this is NoopOpAck;
  String? get reason => switch (this) {
        RejectedOpAck(:final rejectionReason) => rejectionReason.wireName,
        FailedOpAck(:final message) => message,
        AppliedOpAck() || NoopOpAck() => null,
      };
  int? get appliedRevision => switch (this) {
        AppliedOpAck(:final revision) => revision,
        NoopOpAck(:final currentRevision) => currentRevision,
        RejectedOpAck() || FailedOpAck() => null,
      };
  int? get latestRevision => switch (this) {
        RejectedOpAck(:final current) => current?.revision,
        AppliedOpAck() || NoopOpAck() || FailedOpAck() => null,
      };
  CloudPayload? get latestPayload => switch (this) {
        RejectedOpAck(:final current) => current?.value,
        AppliedOpAck() || NoopOpAck() || FailedOpAck() => null,
      };

  factory OpAck.fromJson(Map<String, dynamic> json) {
    final opId = json['opId'] as String;
    return switch (json['status']) {
      'applied' => AppliedOpAck(
          opId: opId,
          revision: _requiredInt(json['appliedRevision']),
        ),
      'noop' => NoopOpAck(
          opId: opId,
          currentRevision: (json['currentRevision'] as num?)?.toInt(),
        ),
      'rejected' => RejectedOpAck(
          opId: opId,
          rejectionReason:
              OpRejectionReason.fromWireName(json['reason'] as String),
          current: json['current'] == null
              ? null
              : CurrentOpSnapshot.fromJson(
                  Map<String, dynamic>.from(json['current'] as Map),
                ),
        ),
      'failed' => FailedOpAck(
          opId: opId,
          code: json['code'] as String,
          rawCode: json['rawCode'] as String,
          message: json['message'] as String,
        ),
      final Object? status =>
        throw FormatException('Unknown op result status: $status'),
    };
  }
}

final class AppliedOpAck extends OpAck {
  const AppliedOpAck({required this.opId, required this.revision});
  @override
  final String opId;
  final int revision;
}

final class NoopOpAck extends OpAck {
  const NoopOpAck({required this.opId, this.currentRevision});
  @override
  final String opId;
  final int? currentRevision;
}

final class RejectedOpAck extends OpAck {
  const RejectedOpAck({
    required this.opId,
    required this.rejectionReason,
    this.current,
  });
  @override
  final String opId;
  final OpRejectionReason rejectionReason;
  final CurrentOpSnapshot? current;
}

final class FailedOpAck extends OpAck {
  const FailedOpAck({
    required this.opId,
    required this.code,
    required this.rawCode,
    required this.message,
  });
  @override
  final String opId;
  final String code;
  final String rawCode;
  final String message;
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
}

class RemotePage {
  const RemotePage({
    required this.publicId,
    required this.strategyPublicId,
    required this.name,
    this.isAutoNamed,
    required this.sortIndex,
    required this.isAttack,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
  });

  final String publicId;
  final String strategyPublicId;
  final String name;
  final bool? isAutoNamed;
  final int sortIndex;
  final bool isAttack;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;
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
}

class ShareRedemption {
  const ShareRedemption({
    required this.targetType,
    required this.role,
    this.folderPublicId,
    this.strategyPublicId,
  });

  final String targetType;
  final String role;
  final String? folderPublicId;
  final String? strategyPublicId;
}
