import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

const strategyId = 'strategy-1';

final strategyCreatedAt = DateTime.utc(2026, 1, 2, 3);

ReadableStrategy strategyRow({
  String publicId = strategyId,
  String name = 'Retake B',
  String mapData = 'ascent',
  String? themeProfileId,
  int revision = 1,
  DateTime? createdAt,
  Map<String, Object?> unknownFields = const {},
}) => ReadableStrategy(
  publicId: publicId,
  name: name,
  mapData: mapData,
  themeProfileId: themeProfileId,
  revision: revision,
  createdAt: createdAt ?? strategyCreatedAt,
  updatedAt: createdAt ?? strategyCreatedAt,
  unknownFields: unknownFields,
);

PageRow page(
  String id, {
  required int sortIndex,
  String? name,
  bool? isAutoNamed,
  bool deleted = false,
  int revision = 1,
}) => deleted
    ? PendingTrashedPage(
        publicId: id,
        strategyPublicId: strategyId,
        name: name ?? 'Page ${sortIndex + 1}',
        isAutoNamed: isAutoNamed,
        sortIndex: sortIndex,
        isAttack: true,
        revision: revision,
      )
    : LivePage(
        publicId: id,
        strategyPublicId: strategyId,
        name: name ?? 'Page ${sortIndex + 1}',
        isAutoNamed: isAutoNamed,
        sortIndex: sortIndex,
        isAttack: true,
        revision: revision,
      );

const defaultSettings = PageSettings(
  agentSize: 1,
  abilitySize: 1,
  useNeutralTeamColors: false,
);

ReadablePageSettings settings(String pageId, {PageSettings? value}) =>
    ReadablePageSettings(
      pagePublicId: pageId,
      settings: value ?? defaultSettings,
      revision: 1,
    );

ElementPayload agentPayload(String id, Map<String, Object?> fields) =>
    ElementPayload(
      kind: ElementKind.agent,
      payloadVersion: 1,
      data: {'id': id, 'elementType': 'agent', ...fields},
    );

LiveElement element(
  String id, {
  String pageId = 'page-a',
  Map<String, Object?> fields = const {},
  int sortIndex = 0,
  int revision = 1,
}) => LiveElement(
  publicId: id,
  pagePublicId: pageId,
  payload: agentPayload(id, fields),
  sortIndex: sortIndex,
  revision: revision,
);

DeletedElement deletedElement(
  String id, {
  String pageId = 'page-a',
  int revision = 2,
}) => DeletedElement(
  publicId: id,
  pagePublicId: pageId,
  payload: agentPayload(id, const {}),
  sortIndex: 0,
  revision: revision,
);

StrategyRowSet strategyRows({
  List<PageRow>? pages,
  List<ElementRow> elements = const [],
  List<LineupGroupRow> lineupGroups = const [],
  List<PageSettingsRow>? pageSettings,
}) {
  final pageRows =
      pages ?? [page('page-a', sortIndex: 0), page('page-b', sortIndex: 1)];
  return StrategyRowSet(
    strategy: strategyRow(),
    pages: pageRows,
    settings:
        pageSettings ?? [for (final row in pageRows) settings(row.publicId)],
    elements: elements,
    lineupGroups: lineupGroups,
  );
}

OpApplied applied(ApplyResult result) {
  if (result is OpApplied) return result;
  fail('Expected the op to apply, got ${describe(result)}');
}

Refusal refused(ApplyResult result) {
  if (result is OpRefused) return result.refusal;
  fail('Expected the op to be refused, got ${describe(result)}');
}

StrategyOp undoOp(OpApplied result) => switch (result.undo) {
  UndoWithOp(:final op) => op,
  final other => fail('Expected an undo op, got $other'),
};

final class Session {
  Session(this.rows);

  StrategyRowSet rows;

  OpApplied apply(StrategyOp op) {
    final result = applied(applyOp(rows, op));
    rows = rows.withRows(result.rows);
    return result;
  }

  ApplyResult attempt(StrategyOp op) => applyOp(rows, op);

  ReadablePageRow pageAt(String pageId) => switch (rows.page(pageId)) {
    final ReadablePageRow page => page,
    final other => fail('$pageId is not a readable page: $other'),
  };

  ReadablePageSettings settingsAt(String pageId) =>
      switch (rows.settingsOf(pageId)) {
        final ReadablePageSettings row => row,
        final other => fail('$pageId has no readable settings: $other'),
      };

  ReadableLineupGroupRow groupAt(String lineupId) =>
      switch (rows.lineupGroup(lineupId)) {
        final ReadableLineupGroupRow row => row,
        final other => fail('$lineupId is not a readable group: $other'),
      };

  Map<String, Object?> dataOf(String elementId) =>
      switch (rows.element(elementId)) {
        LiveElement(:final payload) => payload.data,
        final other => fail('$elementId is not live: $other'),
      };

  int revisionOf(String elementId) => switch (rows.element(elementId)) {
    ReadableElementRow(:final revision) => revision,
    final other => fail('$elementId has no readable revision: $other'),
  };
}

String describe(ApplyResult result) => switch (result) {
  OpApplied() => 'applied',
  OpUnchanged() => 'unchanged',
  OpRefused(:final refusal) => 'refused: $refusal',
};

T readValue<T>(Decoded<T> decoded) => switch (decoded) {
  Read(:final value) => value,
  CouldNotRead(:final problem) => fail('Could not read: $problem'),
};
