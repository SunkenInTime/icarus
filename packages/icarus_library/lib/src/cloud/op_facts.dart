import '../ops.dart';

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
}

final class SettingsTarget extends Target {
  const SettingsTarget(this.pagePublicId);

  final String pagePublicId;

  @override
  bool operator ==(Object other) =>
      other is SettingsTarget && other.pagePublicId == pagePublicId;

  @override
  int get hashCode => Object.hash(SettingsTarget, pagePublicId);
}

final class ElementTarget extends Target {
  const ElementTarget(this.elementPublicId);

  final String elementPublicId;

  @override
  bool operator ==(Object other) =>
      other is ElementTarget && other.elementPublicId == elementPublicId;

  @override
  int get hashCode => Object.hash(ElementTarget, elementPublicId);
}

final class LineupTarget extends Target {
  const LineupTarget(this.lineupPublicId);

  final String lineupPublicId;

  @override
  bool operator ==(Object other) =>
      other is LineupTarget && other.lineupPublicId == lineupPublicId;

  @override
  int get hashCode => Object.hash(LineupTarget, lineupPublicId);
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

StrategyOp rebased(StrategyOp op, int revision) => switch (op) {
  StrategyPatchOp() => StrategyPatchOp(
    opId: op.opId,
    expectedStrategyRevision: revision,
    name: op.name,
    mapData: op.mapData,
    themeProfile: op.themeProfile,
    themeOverridePalette: op.themeOverridePalette,
  ),
  PageAddOp() => PageAddOp(
    opId: op.opId,
    pagePublicId: op.pagePublicId,
    sortIndex: op.sortIndex,
    expectedStrategyRevision: revision,
    name: op.name,
    isAutoNamed: op.isAutoNamed,
    isAttack: op.isAttack,
    settings: op.settings,
    copyContentFromPagePublicId: op.copyContentFromPagePublicId,
  ),
  PagePatchOp() => PagePatchOp(
    opId: op.opId,
    pagePublicId: op.pagePublicId,
    expectedPageRevision: revision,
    name: op.name,
    isAutoNamed: op.isAutoNamed,
    isAttack: op.isAttack,
  ),
  PageDeleteOp() => PageDeleteOp(
    opId: op.opId,
    pagePublicId: op.pagePublicId,
    expectedStrategyRevision: revision,
  ),
  PageReorderOp() => PageReorderOp(
    opId: op.opId,
    pagePublicId: op.pagePublicId,
    sortIndex: op.sortIndex,
    expectedStrategyRevision: revision,
  ),
  PageSettingsPatchOp() => PageSettingsPatchOp(
    opId: op.opId,
    pagePublicId: op.pagePublicId,
    settings: op.settings,
    expectedPageSettingsRevision: revision,
  ),
  ElementAddOp(expectedElementRevision: null) => op,
  ElementAddOp() => ElementAddOp(
    opId: op.opId,
    elementPublicId: op.elementPublicId,
    pagePublicId: op.pagePublicId,
    payload: op.payload,
    sortIndex: op.sortIndex,
    expectedElementRevision: revision,
  ),
  ElementPatchOp() => ElementPatchOp(
    opId: op.opId,
    elementPublicId: op.elementPublicId,
    expectedElementRevision: revision,
    pagePublicId: op.pagePublicId,
    payload: op.payload,
    sortIndex: op.sortIndex,
    merge: op.merge,
  ),
  ElementDeleteOp() => ElementDeleteOp(
    opId: op.opId,
    elementPublicId: op.elementPublicId,
    pagePublicId: op.pagePublicId,
    expectedElementRevision: revision,
    lastWriterWins: op.lastWriterWins,
  ),
  ElementReorderOp() => ElementReorderOp(
    opId: op.opId,
    elementPublicId: op.elementPublicId,
    pagePublicId: op.pagePublicId,
    sortIndex: op.sortIndex,
    expectedElementRevision: revision,
  ),
  LineupGroupAddOp(expectedLineupRevision: null) => op,
  LineupGroupAddOp() => LineupGroupAddOp(
    opId: op.opId,
    lineupPublicId: op.lineupPublicId,
    pagePublicId: op.pagePublicId,
    payload: op.payload,
    sortIndex: op.sortIndex,
    expectedLineupRevision: revision,
  ),
  LineupGroupPatchOp() => LineupGroupPatchOp(
    opId: op.opId,
    lineupPublicId: op.lineupPublicId,
    expectedLineupRevision: revision,
    pagePublicId: op.pagePublicId,
    payload: op.payload,
    sortIndex: op.sortIndex,
    merge: op.merge,
  ),
  LineupGroupDeleteOp() => LineupGroupDeleteOp(
    opId: op.opId,
    lineupPublicId: op.lineupPublicId,
    pagePublicId: op.pagePublicId,
    expectedLineupRevision: revision,
    lastWriterWins: op.lastWriterWins,
  ),
  LineupGroupReorderOp() => LineupGroupReorderOp(
    opId: op.opId,
    lineupPublicId: op.lineupPublicId,
    pagePublicId: op.pagePublicId,
    sortIndex: op.sortIndex,
    expectedLineupRevision: revision,
  ),
};
