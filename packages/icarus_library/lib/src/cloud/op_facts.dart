import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../json.dart';
import '../ops.dart';
import '../rows.dart';
import '../strategy_rows.dart';
import 'pending.dart';

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

Object? _without(Object? json, Set<String> keys) => switch (json) {
  final Map<String, Object?> map => {
    for (final MapEntry(:key, :value) in map.entries)
      if (!keys.contains(key)) key: value,
  },
  _ => json,
};

String rowDigest(Row row) => _digest(switch (row) {
  PageRow() => _without(row.toJson(), const {'revision', 'sortIndex'}),
  _ => _without(row.toJson(), const {'revision'}),
});

String strategyDigest(StrategyRow strategy, Iterable<PageRow> pages) =>
    _digest({
      'strategy': _without(strategy.toJson(), const {
        'revision',
        'updatedAt',
        'createdAt',
      }),
      'pages': [
        for (final page in [
          ...pages,
        ]..sort((a, b) => a.publicId.compareTo(b.publicId)))
          _without(page.toJson(), const {'revision'}),
      ],
    });

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
  UnreadableLineupGroup(:final stored) => switch (stored) {
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
      digest: strategyDigest(rows.strategy, rows.pages),
    );
  }
  return switch ((row, row == null ? null : revisionOfRow(row))) {
    (final row?, final revision?) => AuthoredRow(
      revision: revision,
      digest: rowDigest(row),
    ),
    _ => const AuthoredNoRow(),
  };
}

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
