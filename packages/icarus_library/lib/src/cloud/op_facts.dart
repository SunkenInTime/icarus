import '../ops.dart';
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

bool writesWhole(StrategyOp op) => switch (op) {
  ElementAddOp() ||
  LineupGroupAddOp() ||
  ElementDeleteOp() ||
  LineupGroupDeleteOp() ||
  PageSettingsPatchOp() => true,
  ElementPatchOp(merge: null, payload: _?) ||
  LineupGroupPatchOp(merge: null, payload: _?) => true,
  ElementPatchOp() || LineupGroupPatchOp() => false,
  StrategyPatchOp() ||
  PageAddOp() ||
  PagePatchOp() ||
  PageDeleteOp() ||
  PageReorderOp() ||
  ElementReorderOp() ||
  LineupGroupReorderOp() => false,
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

bool serverChecks(StrategyOp sent) => switch (sent) {
  ElementPatchOp(merge: FieldMerge(base: null)) ||
  LineupGroupPatchOp(merge: FieldMerge(base: null)) => false,
  ElementDeleteOp(lastWriterWins: true) ||
  LineupGroupDeleteOp(lastWriterWins: true) => false,
  _ => true,
};
