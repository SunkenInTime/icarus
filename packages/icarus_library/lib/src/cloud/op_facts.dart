import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../apply.dart';
import '../derived_id.dart';
import '../field_merge.dart';
import '../field_rules.dart';
import '../json.dart';
import '../outcome.dart';
import '../ops.dart';
import '../rows.dart';
import '../strategy_rows.dart';
import 'pending.dart';
import 'version.dart';

sealed class Target {
  const Target();
}

final class StrategyTarget extends Target {
  const StrategyTarget();

  @override
  bool operator ==(Object other) => other is StrategyTarget;

  @override
  int get hashCode => (StrategyTarget).hashCode;
}

final class PageTarget extends Target {
  const PageTarget(this.pagePublicId);

  final String pagePublicId;

  @override
  bool operator ==(Object other) =>
      other is PageTarget && other.pagePublicId == pagePublicId;

  @override
  int get hashCode => Object.hash(PageTarget, pagePublicId);

  @override
  String toString() => 'PageTarget($pagePublicId)';
}

final class SettingsTarget extends Target {
  const SettingsTarget(this.pagePublicId);

  final String pagePublicId;

  @override
  bool operator ==(Object other) =>
      other is SettingsTarget && other.pagePublicId == pagePublicId;

  @override
  int get hashCode => Object.hash(SettingsTarget, pagePublicId);

  @override
  String toString() => 'SettingsTarget($pagePublicId)';
}

final class ElementTarget extends Target {
  const ElementTarget(this.elementPublicId);

  final String elementPublicId;

  @override
  bool operator ==(Object other) =>
      other is ElementTarget && other.elementPublicId == elementPublicId;

  @override
  int get hashCode => Object.hash(ElementTarget, elementPublicId);

  @override
  String toString() => 'ElementTarget($elementPublicId)';
}

final class LineupTarget extends Target {
  const LineupTarget(this.lineupPublicId);

  final String lineupPublicId;

  @override
  bool operator ==(Object other) =>
      other is LineupTarget && other.lineupPublicId == lineupPublicId;

  @override
  int get hashCode => Object.hash(LineupTarget, lineupPublicId);

  @override
  String toString() => 'LineupTarget($lineupPublicId)';
}

Target targetOf(StrategyOp op) => switch (op) {
  StrategyPatchOp() ||
  PageAddOp() ||
  PageDeleteOp() ||
  PageReorderOp() => const StrategyTarget(),
  PagePatchOp(:final pagePublicId) => PageTarget(pagePublicId),
  PageSettingsPatchOp(:final pagePublicId) => SettingsTarget(pagePublicId),
  ElementAddOp(:final elementPublicId) ||
  ElementPatchOp(:final elementPublicId) ||
  ElementDeleteOp(:final elementPublicId) ||
  ElementReorderOp(:final elementPublicId) => ElementTarget(elementPublicId),
  LineupGroupAddOp(:final lineupPublicId) ||
  LineupGroupPatchOp(:final lineupPublicId) ||
  LineupGroupDeleteOp(:final lineupPublicId) ||
  LineupGroupReorderOp(:final lineupPublicId) => LineupTarget(lineupPublicId),
};

bool renumbersPages(StrategyOp op) =>
    op is PageAddOp || op is PageDeleteOp || op is PageReorderOp;

Iterable<String> pagesNeeded(StrategyOp op) => switch (op) {
  StrategyPatchOp() => const [],
  PageAddOp(:final copyContentFromPagePublicId) => [
    ?copyContentFromPagePublicId,
  ],
  PagePatchOp(:final pagePublicId) ||
  PageDeleteOp(:final pagePublicId) ||
  PageReorderOp(:final pagePublicId) ||
  PageSettingsPatchOp(:final pagePublicId) ||
  ElementAddOp(:final pagePublicId) ||
  ElementDeleteOp(:final pagePublicId) ||
  ElementReorderOp(:final pagePublicId) ||
  LineupGroupAddOp(:final pagePublicId) ||
  LineupGroupDeleteOp(:final pagePublicId) ||
  LineupGroupReorderOp(:final pagePublicId) => [pagePublicId],
  ElementPatchOp(:final pagePublicId) ||
  LineupGroupPatchOp(:final pagePublicId) => [?pagePublicId],
};

StrategyOp _rewritten(StrategyOp op, String opId, int? to) => switch (op) {
  StrategyPatchOp() => StrategyPatchOp(
    opId: opId,
    expectedStrategyRevision: to ?? op.expectedStrategyRevision,
    name: op.name,
    mapData: op.mapData,
    themeProfile: op.themeProfile,
    themeOverridePalette: op.themeOverridePalette,
  ),
  PageAddOp() => PageAddOp(
    opId: opId,
    pagePublicId: op.pagePublicId,
    sortIndex: op.sortIndex,
    expectedStrategyRevision: to ?? op.expectedStrategyRevision,
    name: op.name,
    isAutoNamed: op.isAutoNamed,
    isAttack: op.isAttack,
    settings: op.settings,
    copyContentFromPagePublicId: op.copyContentFromPagePublicId,
  ),
  PagePatchOp() => PagePatchOp(
    opId: opId,
    pagePublicId: op.pagePublicId,
    expectedPageRevision: to ?? op.expectedPageRevision,
    name: op.name,
    isAutoNamed: op.isAutoNamed,
    isAttack: op.isAttack,
  ),
  PageDeleteOp() => PageDeleteOp(
    opId: opId,
    pagePublicId: op.pagePublicId,
    expectedStrategyRevision: to ?? op.expectedStrategyRevision,
  ),
  PageReorderOp() => PageReorderOp(
    opId: opId,
    pagePublicId: op.pagePublicId,
    sortIndex: op.sortIndex,
    expectedStrategyRevision: to ?? op.expectedStrategyRevision,
  ),
  PageSettingsPatchOp() => PageSettingsPatchOp(
    opId: opId,
    pagePublicId: op.pagePublicId,
    settings: op.settings,
    expectedPageSettingsRevision: to ?? op.expectedPageSettingsRevision,
  ),
  ElementAddOp() => ElementAddOp(
    opId: opId,
    elementPublicId: op.elementPublicId,
    pagePublicId: op.pagePublicId,
    payload: op.payload,
    sortIndex: op.sortIndex,
    expectedElementRevision: to ?? op.expectedElementRevision,
  ),
  ElementPatchOp() => ElementPatchOp(
    opId: opId,
    elementPublicId: op.elementPublicId,
    expectedElementRevision: to ?? op.expectedElementRevision,
    pagePublicId: op.pagePublicId,
    payload: op.payload,
    sortIndex: op.sortIndex,
    merge: op.merge,
  ),
  ElementDeleteOp() => ElementDeleteOp(
    opId: opId,
    elementPublicId: op.elementPublicId,
    pagePublicId: op.pagePublicId,
    expectedElementRevision: to ?? op.expectedElementRevision,
    lastWriterWins: op.lastWriterWins,
  ),
  ElementReorderOp() => ElementReorderOp(
    opId: opId,
    elementPublicId: op.elementPublicId,
    pagePublicId: op.pagePublicId,
    sortIndex: op.sortIndex,
    expectedElementRevision: to ?? op.expectedElementRevision,
  ),
  LineupGroupAddOp() => LineupGroupAddOp(
    opId: opId,
    lineupPublicId: op.lineupPublicId,
    pagePublicId: op.pagePublicId,
    payload: op.payload,
    sortIndex: op.sortIndex,
    expectedLineupRevision: to ?? op.expectedLineupRevision,
  ),
  LineupGroupPatchOp() => LineupGroupPatchOp(
    opId: opId,
    lineupPublicId: op.lineupPublicId,
    expectedLineupRevision: to ?? op.expectedLineupRevision,
    pagePublicId: op.pagePublicId,
    payload: op.payload,
    sortIndex: op.sortIndex,
    merge: op.merge,
  ),
  LineupGroupDeleteOp() => LineupGroupDeleteOp(
    opId: opId,
    lineupPublicId: op.lineupPublicId,
    pagePublicId: op.pagePublicId,
    expectedLineupRevision: to ?? op.expectedLineupRevision,
    lastWriterWins: op.lastWriterWins,
  ),
  LineupGroupReorderOp() => LineupGroupReorderOp(
    opId: opId,
    lineupPublicId: op.lineupPublicId,
    pagePublicId: op.pagePublicId,
    sortIndex: op.sortIndex,
    expectedLineupRevision: to ?? op.expectedLineupRevision,
  ),
};

StrategyOp rebased(StrategyOp op, int revision) => switch (expectedOf(op)) {
  null => op,
  _ => _rewritten(op, op.opId, revision),
};

StrategyOp renamed(StrategyOp op, String opId) => _rewritten(op, opId, null);

int? expectedOf(StrategyOp op) => switch (op) {
  StrategyPatchOp(:final expectedStrategyRevision) ||
  PageAddOp(:final expectedStrategyRevision) ||
  PageDeleteOp(:final expectedStrategyRevision) ||
  PageReorderOp(:final expectedStrategyRevision) => expectedStrategyRevision,
  PagePatchOp(:final expectedPageRevision) => expectedPageRevision,
  PageSettingsPatchOp(:final expectedPageSettingsRevision) =>
    expectedPageSettingsRevision,
  ElementAddOp(:final expectedElementRevision) => expectedElementRevision,
  ElementPatchOp(:final expectedElementRevision) ||
  ElementDeleteOp(:final expectedElementRevision) ||
  ElementReorderOp(:final expectedElementRevision) => expectedElementRevision,
  LineupGroupAddOp(:final expectedLineupRevision) => expectedLineupRevision,
  LineupGroupPatchOp(:final expectedLineupRevision) ||
  LineupGroupDeleteOp(:final expectedLineupRevision) ||
  LineupGroupReorderOp(:final expectedLineupRevision) => expectedLineupRevision,
};

StrategyOp sendForm(StrategyOp op, SendPolicy policy) {
  final live = policy == SendPolicy.live;
  return switch (op) {
    ElementPatchOp(merge: FieldMerge(base: _?, :final fields)) when live =>
      ElementPatchOp(
        opId: op.opId,
        elementPublicId: op.elementPublicId,
        expectedElementRevision: op.expectedElementRevision,
        pagePublicId: op.pagePublicId,
        payload: op.payload,
        sortIndex: op.sortIndex,
        merge: FieldMerge(fields: fields),
      ),
    LineupGroupPatchOp(merge: FieldMerge(base: _?, :final fields)) when live =>
      LineupGroupPatchOp(
        opId: op.opId,
        lineupPublicId: op.lineupPublicId,
        expectedLineupRevision: op.expectedLineupRevision,
        pagePublicId: op.pagePublicId,
        payload: op.payload,
        sortIndex: op.sortIndex,
        merge: FieldMerge(fields: fields),
      ),
    ElementDeleteOp(:final lastWriterWins) when lastWriterWins != live =>
      ElementDeleteOp(
        opId: op.opId,
        elementPublicId: op.elementPublicId,
        pagePublicId: op.pagePublicId,
        expectedElementRevision: op.expectedElementRevision,
        lastWriterWins: live,
      ),
    LineupGroupDeleteOp(:final lastWriterWins) when lastWriterWins != live =>
      LineupGroupDeleteOp(
        opId: op.opId,
        lineupPublicId: op.lineupPublicId,
        pagePublicId: op.pagePublicId,
        expectedLineupRevision: op.expectedLineupRevision,
        lastWriterWins: live,
      ),
    _ => op,
  };
}

enum CheckKind { revision, fields, none }

CheckKind checkKindOf(StrategyOp sent) => switch (sent) {
  ElementPatchOp(merge: FieldMerge(base: _?)) ||
  LineupGroupPatchOp(merge: FieldMerge(base: _?)) => CheckKind.fields,
  ElementPatchOp(merge: FieldMerge()) ||
  LineupGroupPatchOp(merge: FieldMerge()) => CheckKind.none,
  ElementDeleteOp(lastWriterWins: true) ||
  LineupGroupDeleteOp(lastWriterWins: true) => CheckKind.none,
  ElementAddOp(expectedElementRevision: null) ||
  LineupGroupAddOp(expectedLineupRevision: null) => CheckKind.none,
  _ => CheckKind.revision,
};

sealed class Entity {
  const Entity();
}

final class TheStrategy extends Entity {
  const TheStrategy();

  @override
  bool operator ==(Object other) => other is TheStrategy;

  @override
  int get hashCode => (TheStrategy).hashCode;
}

final class ThePage extends Entity {
  const ThePage(this.pagePublicId);

  final String pagePublicId;

  @override
  bool operator ==(Object other) =>
      other is ThePage && other.pagePublicId == pagePublicId;

  @override
  int get hashCode => Object.hash(ThePage, pagePublicId);
}

final class TheRow extends Entity {
  const TheRow(this.target);

  final Target target;

  @override
  bool operator ==(Object other) => other is TheRow && other.target == target;

  @override
  int get hashCode => Object.hash(TheRow, target);
}

Entity entityOf(StrategyOp op) => switch (op) {
  StrategyPatchOp() => const TheStrategy(),
  PageAddOp(:final pagePublicId) ||
  PageDeleteOp(:final pagePublicId) ||
  PageReorderOp(:final pagePublicId) ||
  PagePatchOp(:final pagePublicId) => ThePage(pagePublicId),
  _ => TheRow(targetOf(op)),
};

String _digest(Object? json) => sha256
    .convert(utf8.encode(canonicalJson(json)))
    .toString()
    .substring(0, 32);

Object? _drawn(Object? data) => switch (withFieldDefaults(data)) {
  final Map<String, Object?> object => {
    for (final MapEntry(:key, :value) in object.entries)
      if (value != null) key: _drawn(value),
  },
  final List<Object?> list => [for (final item in list) _drawn(item)],
  final other => other,
};

Object? _visiblePart(Row row) => switch (row) {
  ReadableElementRow(:final pagePublicId, :final payload, :final sortIndex) => {
    'page': pagePublicId,
    'sortIndex': sortIndex,
    'live': row is LiveElement,
    'kind': payload.kind.name,
    'data': _drawn(payload.data),
  },
  ReadableLineupGroupRow(
    :final pagePublicId,
    :final payload,
    :final sortIndex,
  ) =>
    {
      'page': pagePublicId,
      'sortIndex': sortIndex,
      'live': row is LiveLineupGroup,
      'data': _drawn(payload.data),
    },
  ReadablePageRow(:final name, :final isAutoNamed, :final isAttack) => {
    'name': name,
    'isAutoNamed': isAutoNamed ?? false,
    'isAttack': isAttack,
    'live': row is LivePage,
  },
  ReadablePageSettings(:final settings) => {
    'agentSize': settings?.agentSize,
    'abilitySize': settings?.abilitySize,
    'useNeutralTeamColors': settings?.useNeutralTeamColors,
  },
  ReadableStrategy() => _strategyPart(row),
  UnreadableStrategy(:final stored) ||
  UnreadablePage(:final stored) ||
  UnreadablePageSettings(:final stored) ||
  UnreadableElement(:final stored) ||
  UnreadableLineupGroup(:final stored) => {'unreadable': plainJson(stored)},
  FolderRow() => null,
};

Map<String, Object?> _strategyPart(ReadableStrategy strategy) => {
  'name': strategy.name,
  'mapData': strategy.mapData,
  'themeProfileId': strategy.themeProfileId,
  'themeOverridePalette': strategy.themeOverridePalette?.toJson(),
};

String rowDigest(Row row) => _digest(_visiblePart(row));

String strategyDigest(StrategyRow strategy, Iterable<PageRow> pages) {
  final live =
      [
        for (final page in pages)
          if (page is LivePage) page,
      ]..sort(
        (a, b) => a.sortIndex != b.sortIndex
            ? a.sortIndex.compareTo(b.sortIndex)
            : a.publicId.compareTo(b.publicId),
      );
  return _digest({
    'strategy': switch (strategy) {
      final ReadableStrategy readable => _strategyPart(readable),
      UnreadableStrategy(:final stored) => {'unreadable': plainJson(stored)},
    },
    'pages': [for (final page in live) page.publicId],
  });
}

RowLife lifeOf(Row row) => switch (createdAtOf(row)) {
  final life? => BornAt(life),
  null => const NotYetBorn(),
};

Version? versionOfRow(Row row) =>
    switch ((createdAtOf(row), revisionOfRow(row))) {
      (final life?, final revision?) => Version(life, revision),
      _ => null,
    };

int? revisionOfRow(Row row) => switch (row) {
  ReadableStrategy(:final revision) ||
  ReadablePageRow(:final revision) ||
  ReadablePageSettings(:final revision) ||
  ReadableElementRow(:final revision) ||
  ReadableLineupGroupRow(:final revision) => revision,
  UnreadableStrategy(:final stored) ||
  UnreadablePage(:final stored) ||
  UnreadablePageSettings(:final stored) ||
  UnreadableElement(:final stored) ||
  UnreadableLineupGroup(:final stored) => switch (plainJson(stored)) {
    {'revision': final int revision} => revision,
    _ => null,
  },
  FolderRow() => null,
};

Life lifeOfRow(Row row) => switch (row) {
  DeletedElement() || DeletedLineupGroup() || TrashedPage() => Life.gone,
  UnreadableElement(deleted: true) => Life.gone,
  UnreadablePage(trashed: true) => Life.gone,
  _ => Life.live,
};

Authored authoredFor(StrategyRows rows, StrategyOp op) {
  final row = switch (targetOf(op)) {
    StrategyTarget() => null,
    PageTarget(:final pagePublicId) => rows.page(pagePublicId),
    SettingsTarget(:final pagePublicId) => rows.settingsOf(pagePublicId),
    ElementTarget(:final elementPublicId) => rows.element(elementPublicId),
    LineupTarget(:final lineupPublicId) => rows.lineupGroup(lineupPublicId),
  };
  if (targetOf(op) is StrategyTarget) {
    return AuthoredRow(
      revision: rows.strategy.revision,
      life: lifeOf(rows.strategy),
      digest: strategyDigest(rows.strategy, rows.pages),
      produces: producedBy(rows, op),
    );
  }
  return switch ((row, row == null ? null : revisionOfRow(row))) {
    (final row?, final revision?) => AuthoredRow(
      revision: revision,
      life: lifeOf(row),
      digest: rowDigest(row),
      payloadVersion: switch (row) {
        ReadableElementRow(:final payload) => payload.payloadVersion,
        ReadableLineupGroupRow(:final payload) => payload.payloadVersion,
        _ => null,
      },
      produces: producedBy(rows, op),
      movedRow: switch ((op, row)) {
        (
          ElementPatchOp(pagePublicId: final to?),
          LiveElement(:final pagePublicId),
        ) ||
        (
          LineupGroupPatchOp(pagePublicId: final to?),
          LiveLineupGroup(:final pagePublicId),
        ) when to != pagePublicId => row,
        _ => null,
      },
    ),
    (_?, null) => const AuthoredUnreadable(),
    (null, _) => AuthoredNoRow(produces: producedBy(rows, op)),
  };
}

ProducedRow? producedBy(StrategyRows rows, StrategyOp op) {
  final target = targetOf(op);
  final List<Row>? after = switch (applyOp(rows, op)) {
    final OpApplied done => done.rows.toList(),
    OpUnchanged() => [?_rowAt(rows, target)],
    _ => null,
  };
  if (after == null) return null;
  if (target is StrategyTarget) {
    final strategy = after.whereType<ReadableStrategy>().firstOrNull;
    if (strategy == null) return null;
    final changed = {
      for (final row in after)
        if (row is PageRow) row.publicId: row,
    };
    return ProducedRow(
      page: null,
      revision: strategy.revision,
      life: lifeOf(strategy),
      digest: strategyDigest(strategy, [
        for (final page in rows.pages) changed.remove(page.publicId) ?? page,
        ...changed.values,
      ]),
    );
  }
  for (final row in after) {
    final rowTarget = switch (row) {
      PageRow(:final publicId) => PageTarget(publicId) as Target,
      PageSettingsRow(:final pagePublicId) => SettingsTarget(pagePublicId),
      ElementRow(:final publicId) => ElementTarget(publicId),
      LineupGroupRow(:final publicId) => LineupTarget(publicId),
      _ => null,
    };
    if (rowTarget != target) continue;
    final revision = revisionOfRow(row);
    if (revision == null) return null;
    return ProducedRow(
      life: lifeOf(row),
      page: switch (row) {
        PageRow(:final publicId) => publicId,
        PageSettingsRow(:final pagePublicId) => pagePublicId,
        ElementRow(:final pagePublicId) => pagePublicId,
        LineupGroupRow(:final pagePublicId) => pagePublicId,
        _ => null,
      },
      revision: revision,
      digest: rowDigest(row),
    );
  }
  return null;
}

Row? _rowAt(StrategyRows rows, Target target) => switch (target) {
  StrategyTarget() => rows.strategy,
  PageTarget(:final pagePublicId) => rows.page(pagePublicId),
  SettingsTarget(:final pagePublicId) => rows.settingsOf(pagePublicId),
  ElementTarget(:final elementPublicId) => rows.element(elementPublicId),
  LineupTarget(:final lineupPublicId) => rows.lineupGroup(lineupPublicId),
};

Map<SeenPart, String> liveContentOn(Iterable<Row> rows, String pagePublicId) =>
    {
      for (final row in rows)
        if (lifeOfRow(row) == Life.live)
          switch (row) {
            PageSettingsRow() => const SeenSettings(),
            ElementRow(:final publicId) => SeenElement(publicId),
            LineupGroupRow(:final publicId) => SeenLineupGroup(publicId),
            _ => const SeenSettings(),
          }: rowDigest(
            row,
          ),
    };

SeenPage seenPageIn(StrategyRows rows, String pagePublicId) {
  final page = rows.page(pagePublicId);
  return SeenPage(
    pageDigest: page == null ? '' : rowDigest(page),
    pageRevision: page == null ? 0 : (revisionOfRow(page) ?? 0),
    content: ContentSeen(
      liveContentOn([
        ?rows.settingsOf(pagePublicId),
        ...rows.elementsOn(pagePublicId),
        ...rows.lineupGroupsOn(pagePublicId),
      ], pagePublicId),
    ),
  );
}

StrategyOp withFieldBase(StrategyRows rows, StrategyOp op) => switch (op) {
  ElementPatchOp(merge: FieldMerge(base: null, :final fields)) => switch (rows
      .element(op.elementPublicId)) {
    ReadableElementRow(:final payload, :final sortIndex) => ElementPatchOp(
      opId: op.opId,
      elementPublicId: op.elementPublicId,
      expectedElementRevision: op.expectedElementRevision,
      pagePublicId: op.pagePublicId,
      payload: op.payload,
      sortIndex: op.sortIndex,
      merge: FieldMerge(
        fields: fields,
        base: elementMergeBase(payload, sortIndex, fields),
      ),
    ),
    _ => op,
  },
  LineupGroupPatchOp(merge: FieldMerge(base: null, :final fields)) =>
    switch (rows.lineupGroup(op.lineupPublicId)) {
      ReadableLineupGroupRow(:final payload, :final sortIndex) =>
        LineupGroupPatchOp(
          opId: op.opId,
          lineupPublicId: op.lineupPublicId,
          expectedLineupRevision: op.expectedLineupRevision,
          pagePublicId: op.pagePublicId,
          payload: op.payload,
          sortIndex: op.sortIndex,
          merge: FieldMerge(
            fields: fields,
            base: lineupMergeBase(payload, sortIndex, fields),
          ),
        ),
      _ => op,
    },
  _ => op,
};

sealed class CopyExpansion {
  const CopyExpansion();
}

final class CopyExpanded extends CopyExpansion {
  CopyExpanded(List<StrategyOp> ops) : ops = List.unmodifiable(ops);

  final List<StrategyOp> ops;
}

final class CopyNotExpanded extends CopyExpansion {
  const CopyNotExpanded(this.result);

  final ApplyResult result;
}

CopyExpansion expandCopy(StrategyRows rows, PageAddOp copy) {
  final OpApplied applied;
  switch (applyOp(rows, copy)) {
    case final OpApplied done:
      applied = done;
    case final other:
      return CopyNotExpanded(other);
  }
  var made = 0;
  String opId() => derivedId(jsonEncode([copy.opId, 'expanded', made++]));
  final ops = <StrategyOp>[
    PageAddOp(
      opId: copy.opId,
      pagePublicId: copy.pagePublicId,
      sortIndex: copy.sortIndex,
      expectedStrategyRevision: copy.expectedStrategyRevision,
      name: copy.name,
      isAutoNamed: copy.isAutoNamed,
      isAttack: copy.isAttack,
      settings: copy.settings,
    ),
  ];
  for (final write in applied.writes) {
    switch (write) {
      case RowAdded(after: final LiveElement row):
        ops.add(
          ElementAddOp(
            opId: opId(),
            elementPublicId: row.publicId,
            pagePublicId: row.pagePublicId,
            payload: row.payload,
            sortIndex: row.sortIndex,
          ),
        );
      case RowAdded(after: final LiveLineupGroup row):
        ops.add(
          LineupGroupAddOp(
            opId: opId(),
            lineupPublicId: row.publicId,
            pagePublicId: row.pagePublicId,
            payload: row.payload,
            sortIndex: row.sortIndex,
          ),
        );
      case RowAdded(after: ElementRow() || LineupGroupRow()):
        return CopyNotExpanded(OpRefused(UnreadableTarget(write.key)));
      case RowAdded() || RowChanged():
        break;
    }
  }
  return CopyExpanded(ops);
}
