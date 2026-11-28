import 'package:icarus_library/icarus_library.dart';

import 'merge_seeds.dart' show OutcomeJson, RowsJson;
import 'merge_stories.dart';

const rowPage = 'p0';
const namedPage = 'p1';

typedef _Subject = StrategyOp Function(StrategyRowSet rows);

LiveElement _jett(StrategyRowSet rows) => rows.element('jett')! as LiveElement;

LiveLineupGroup _g0(StrategyRowSet rows) =>
    rows.lineupGroup('g0')! as LiveLineupGroup;

ElementPayload _moved(LiveElement row) => ElementPayload(
  kind: row.payload.kind,
  payloadVersion: row.payload.payloadVersion,
  data: {
    ...row.payload.data.toJson(),
    'position': {'x': 7, 'y': 7},
  },
);

ElementPayload _fresh(LiveElement row) => ElementPayload(
  kind: row.payload.kind,
  payloadVersion: row.payload.payloadVersion,
  data: {...row.payload.data.toJson(), 'id': 'fresh'},
);

LineupGroupPayload _group(LiveLineupGroup row, {String? id, String? notes}) =>
    LineupGroupPayload(
      payloadVersion: row.payload.payloadVersion,
      data: {
        ...row.payload.data.toJson(),
        'id': ?id,
        if (notes != null)
          'links': [
            for (final link in row.payload.data.toJson()['links']! as List)
              {...link as Map<String, Object?>, 'notes': notes},
          ],
      },
    );

ElementPatchOp _edit(StrategyRowSet rows, String opId, {String? page}) =>
    switch (elementEditOp(
      opId: opId,
      base: _jett(rows),
      drawn: DrawnAt(_jett(rows).revision),
      payload: _moved(_jett(rows)),
      sortIndex: _jett(rows).sortIndex,
      connection: Connection.live,
    )) {
      final edit => ElementPatchOp(
        opId: edit.opId,
        elementPublicId: edit.elementPublicId,
        expectedElementRevision: edit.expectedElementRevision,
        pagePublicId: page,
        payload: edit.payload,
        sortIndex: edit.sortIndex,
        merge: edit.merge,
      ),
    };

final Map<String, _Subject> _subjects = {
  'element.add of a new row on the named page': (rows) => ElementAddOp(
    opId: 'subject',
    elementPublicId: 'fresh',
    pagePublicId: namedPage,
    payload: _fresh(_jett(rows)),
    sortIndex: 0,
  ),
  'element.add of an existing row naming another page': (rows) => ElementAddOp(
    opId: 'subject',
    elementPublicId: 'jett',
    pagePublicId: namedPage,
    payload: _jett(rows).payload,
    sortIndex: 0,
  ),
  'element.patch merged, naming the row\'s page': (rows) =>
      _edit(rows, 'subject', page: rowPage),
  'element.patch merged, naming another page': (rows) =>
      _edit(rows, 'subject', page: namedPage),
  'element.patch merged, naming no page': (rows) => _edit(rows, 'subject'),
  'element.patch whole, naming another page (a move)': (rows) => ElementPatchOp(
    opId: 'subject',
    elementPublicId: 'jett',
    expectedElementRevision: _jett(rows).revision,
    pagePublicId: namedPage,
    payload: _jett(rows).payload,
    sortIndex: 3,
  ),
  'element.patch whole, naming no page': (rows) => ElementPatchOp(
    opId: 'subject',
    elementPublicId: 'jett',
    expectedElementRevision: _jett(rows).revision,
    payload: _moved(_jett(rows)),
    sortIndex: _jett(rows).sortIndex,
  ),
  'element.delete naming the row\'s page': (rows) => ElementDeleteOp(
    opId: 'subject',
    elementPublicId: 'jett',
    pagePublicId: rowPage,
    expectedElementRevision: _jett(rows).revision,
  ),
  'element.delete naming another page': (rows) => ElementDeleteOp(
    opId: 'subject',
    elementPublicId: 'jett',
    pagePublicId: namedPage,
    expectedElementRevision: _jett(rows).revision,
  ),
  'element.reorder naming another page': (rows) => ElementReorderOp(
    opId: 'subject',
    elementPublicId: 'jett',
    pagePublicId: namedPage,
    sortIndex: 4,
    expectedElementRevision: _jett(rows).revision,
  ),
  'lineup.add of a new group on the named page': (rows) => LineupGroupAddOp(
    opId: 'subject',
    lineupPublicId: 'fresh',
    pagePublicId: namedPage,
    payload: _group(_g0(rows), id: 'fresh'),
    sortIndex: 0,
  ),
  'lineup.add of an existing group naming another page': (rows) =>
      LineupGroupAddOp(
        opId: 'subject',
        lineupPublicId: 'g0',
        pagePublicId: namedPage,
        payload: _g0(rows).payload,
        sortIndex: 0,
      ),
  'lineup.patch naming the row\'s page': (rows) => LineupGroupPatchOp(
    opId: 'subject',
    lineupPublicId: 'g0',
    expectedLineupRevision: _g0(rows).revision,
    pagePublicId: rowPage,
    payload: _group(_g0(rows), notes: 'edited'),
  ),
  'lineup.patch naming another page': (rows) => LineupGroupPatchOp(
    opId: 'subject',
    lineupPublicId: 'g0',
    expectedLineupRevision: _g0(rows).revision,
    pagePublicId: namedPage,
    payload: _group(_g0(rows), notes: 'edited'),
  ),
  'lineup.patch naming no page': (rows) => LineupGroupPatchOp(
    opId: 'subject',
    lineupPublicId: 'g0',
    expectedLineupRevision: _g0(rows).revision,
    payload: _group(_g0(rows), notes: 'edited'),
  ),
  'lineup.delete naming another page': (rows) => LineupGroupDeleteOp(
    opId: 'subject',
    lineupPublicId: 'g0',
    pagePublicId: namedPage,
    expectedLineupRevision: _g0(rows).revision,
  ),
  'lineup.reorder naming another page': (rows) => LineupGroupReorderOp(
    opId: 'subject',
    lineupPublicId: 'g0',
    pagePublicId: namedPage,
    sortIndex: 4,
    expectedLineupRevision: _g0(rows).revision,
  ),
  'page.add reusing the named page\'s id': (rows) => PageAddOp(
    opId: 'subject',
    pagePublicId: namedPage,
    sortIndex: 0,
    expectedStrategyRevision: rows.strategy.revision,
  ),
  'page.patch of the named page': (rows) => PagePatchOp(
    opId: 'subject',
    pagePublicId: namedPage,
    expectedPageRevision: (rows.page(namedPage)! as ReadablePageRow).revision,
    name: 'Renamed',
  ),
  'page.reorder of the named page': (rows) => PageReorderOp(
    opId: 'subject',
    pagePublicId: namedPage,
    sortIndex: 0,
    expectedStrategyRevision: rows.strategy.revision,
  ),
  'page.settings of the named page': (rows) => PageSettingsPatchOp(
    opId: 'subject',
    pagePublicId: namedPage,
    settings: const PageSettings(
      agentSize: 2,
      abilitySize: 1,
      useNeutralTeamColors: false,
    ),
    expectedPageSettingsRevision:
        (rows.settingsOf(namedPage)! as ReadablePageSettings).revision,
  ),
  'page.delete of the named page': (rows) => PageDeleteOp(
    opId: 'subject',
    pagePublicId: namedPage,
    expectedStrategyRevision: rows.strategy.revision,
  ),
  'strategy.patch': (rows) => StrategyPatchOp(
    opId: 'subject',
    expectedStrategyRevision: rows.strategy.revision,
    name: 'Renamed',
  ),
};

String? _liveRowPage(StrategyRows rows, StrategyOp op) =>
    switch (targetOf(op)) {
      ElementTarget(:final elementPublicId) => switch (rows.element(
        elementPublicId,
      )) {
        LiveElement(:final pagePublicId) => pagePublicId,
        _ => null,
      },
      LineupTarget(:final lineupPublicId) => switch (rows.lineupGroup(
        lineupPublicId,
      )) {
        LiveLineupGroup(:final pagePublicId) => pagePublicId,
        _ => null,
      },
      _ => null,
    };

List<Map<String, Object?>> trashCaseScenarios(
  RowsJson rowsJson,
  OutcomeJson outcomeJson,
) => [
  for (final MapEntry(key: kind, value: subject) in _subjects.entries)
    for (final rowTrashed in [false, true])
      for (final namedTrashed in [false, true])
        _scenario(
          kind,
          subject,
          rowTrashed: rowTrashed,
          namedTrashed: namedTrashed,
          rowsJson: rowsJson,
          outcomeJson: outcomeJson,
        ),
];

Map<String, Object?> _scenario(
  String kind,
  _Subject subject, {
  required bool rowTrashed,
  required bool namedTrashed,
  required RowsJson rowsJson,
  required OutcomeJson outcomeJson,
}) {
  var rows = storyRows;
  final ops = <StrategyOp>[];
  final predicted = <Map<String, Object?>>[];
  void apply(StrategyOp Function(StrategyRowSet rows) build) {
    final op = build(rows);
    final result = applyOp(rows, op);
    if (result is OpApplied) rows = rows.withRows(result.rows);
    ops.add(op);
    predicted.add({...outcomeJson(result, op, rows), 'rows': rowsJson(rows)});
  }

  apply(
    (rows) => PageAddOp(
      opId: 'keep-one-live',
      pagePublicId: 'p2',
      sortIndex: 2,
      expectedStrategyRevision: rows.strategy.revision,
    ),
  );
  for (final (page, trashed) in [
    (rowPage, rowTrashed),
    (namedPage, namedTrashed),
  ]) {
    if (!trashed) continue;
    apply(
      (rows) => PageDeleteOp(
        opId: 'trash-$page',
        pagePublicId: page,
        expectedStrategyRevision: rows.strategy.revision,
      ),
    );
  }
  final before = rows;
  final op = subject(before);
  final pages = pagesRequiredLive(op, rowPage: _liveRowPage(before, op));
  final needsTrashedPage = pages.any(
    (page) => before.page(page) is TrashedPage,
  );
  apply((_) => op);
  return {
    'name':
        'trash case: $kind, row\'s page ${rowTrashed ? 'trashed' : 'live'}, '
        'named page ${namedTrashed ? 'trashed' : 'live'}',
    'initial': rowsJson(storyRows),
    'ops': [for (final op in ops) op.toJson()],
    'predicted': predicted,
    'trashCase': {
      'kind': kind,
      'rowTrashed': rowTrashed,
      'namedTrashed': namedTrashed,
      'needsTrashedPage': needsTrashedPage,
    },
  };
}
