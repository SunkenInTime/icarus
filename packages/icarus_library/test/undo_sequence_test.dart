import 'dart:convert';
import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'support.dart';

Map<String, Object?> _origin(String id) => {
  'id': id,
  'agent': {'type': 'sova', 'lineUpID': id},
};

Map<String, Object?> _landing(String id) => {
  'id': id,
  'ability': {'type': 'recon', 'lineUpID': id},
};

Map<String, Object?> _link(String id, String origin, String landing) => {
  'id': id,
  'originId': origin,
  'landingId': landing,
  'notes': id,
};

LineupGroupPayload _groupPayload() => LineupGroupPayload(
  payloadVersion: 1,
  data: {
    'id': 'g1',
    'origins': [_origin('o1'), _origin('o2')],
    'landings': [_landing('l1'), _landing('l2')],
    'links': [
      _link('k1', 'o1', 'l1'),
      _link('k2', 'o2', 'l1'),
      _link('k3', 'o2', 'l2'),
    ],
  },
);

LineupGroupPayload _twoLinks(String id) => LineupGroupPayload(
  payloadVersion: 1,
  data: {
    'id': id,
    'origins': [_origin('$id-o')],
    'landings': [_landing('$id-l')],
    'links': [
      _link('$id-k1', '$id-o', '$id-l'),
      _link('$id-k2', '$id-o', '$id-l'),
    ],
  },
);

StrategyRowSet _start({required bool legacy}) => StrategyRowSet(
  strategy: ReadableStrategy(
    publicId: strategyId,
    name: 'Retake B',
    mapData: 'ascent',
    revision: 1,
    createdAt: strategyCreatedAt,
    updatedAt: strategyCreatedAt,
    themeOverridePalette: const ThemePalette(
      base: '#000',
      detail: '#001',
      highlight: '#002',
    ),
  ),
  pages: [
    page('page-a', sortIndex: 0, isAutoNamed: legacy ? null : true),
    page('page-b', sortIndex: 1),
  ],
  settings: [
    legacy
        ? ReadablePageSettings(pagePublicId: 'page-a', revision: 1)
        : settings('page-a'),
    settings('page-b'),
  ],
  elements: [
    element(
      'jett',
      fields: {
        'type': 'jett',
        'position': {'x': 1, 'y': 1},
        'isAlly': true,
        'caption': 'entry',
      },
    ),
    element(
      'sova',
      sortIndex: 1,
      fields: {
        'type': 'sova',
        'position': {'x': 2, 'y': 2},
      },
    ),
    DeletedElement(
      publicId: 'ghost',
      pagePublicId: 'page-a',
      payload: agentPayload('ghost', {'type': 'omen'}),
      sortIndex: 2,
      revision: 2,
    ),
  ],
  lineupGroups: [
    DeletedLineupGroup(
      strategyPublicId: strategyId,
      publicId: 'g0',
      pagePublicId: 'page-a',
      payload: _twoLinks('g0'),
      sortIndex: 1,
      revision: 2,
    ),
    LiveLineupGroup(
      strategyPublicId: strategyId,
      publicId: 'g1',
      pagePublicId: 'page-a',
      payload: _groupPayload(),
      sortIndex: 0,
      revision: 1,
    ),
  ],
);

typedef _Edit = StrategyOp? Function(StrategyRowSet rows, String opId);

final class _Edits {
  _Edits(this.random);

  final Random random;
  var _fresh = 0;

  T pick<T>(List<T> items) => items[random.nextInt(items.length)];

  List<LiveElement> live(StrategyRowSet rows) => [
    for (final row in rows.elements)
      if (row case final LiveElement live when live.pagePublicId == 'page-a')
        live,
  ];

  LiveLineupGroup? group(StrategyRowSet rows) =>
      switch (rows.lineupGroup('g1')) {
        final LiveLineupGroup live => live,
        _ => null,
      };

  StrategyOp? elementMerge(
    StrategyRowSet rows,
    String opId,
    Map<String, Object?> Function(LiveElement row) change,
  ) {
    final rowsHere = live(rows);
    if (rowsHere.isEmpty) return null;
    final row = pick(rowsHere);
    return elementEditOp(
      opId: opId,
      base: row,
      drawn: DrawnAt(row.revision),
      payload: row.payload.withData({
        ...row.payload.data.toJson(),
        ...change(row),
      }),
      sortIndex: row.sortIndex,
      connection: Connection.live,
    );
  }

  StrategyOp? groupEdit(
    StrategyRowSet rows,
    String opId,
    Map<String, Object?>? Function(Map<String, Object?> data) change,
  ) {
    final row = group(rows);
    if (row == null) return null;
    final data = change(row.payload.data.toJson());
    if (data == null) return null;
    return lineupEditOp(
      opId: opId,
      base: row,
      drawn: DrawnAt(row.revision),
      payload: row.payload.withData(data),
      sortIndex: row.sortIndex,
      connection: Connection.live,
    );
  }

  late final Map<String, _Edit> all = {
    'move an agent': (rows, opId) => elementMerge(
      rows,
      opId,
      (_) => {
        'position': {'x': random.nextInt(50), 'y': random.nextInt(50)},
      },
    ),
    'caption an agent': (rows, opId) =>
        elementMerge(rows, opId, (_) => {'caption': 'c${random.nextInt(9)}'}),
    'rewrite an agent whole': (rows, opId) {
      final rowsHere = live(rows);
      if (rowsHere.isEmpty) return null;
      final row = pick(rowsHere);
      return ElementPatchOp(
        opId: opId,
        elementPublicId: row.publicId,
        expectedElementRevision: row.revision,
        payload: row.payload.withData({
          'id': row.publicId,
          'elementType': 'agent',
          'type': row.payload.data['type'],
          'position': {'x': random.nextInt(50), 'y': 99},
        }),
      );
    },
    'reorder an agent': (rows, opId) {
      final rowsHere = live(rows);
      if (rowsHere.isEmpty) return null;
      final row = pick(rowsHere);
      return ElementReorderOp(
        opId: opId,
        elementPublicId: row.publicId,
        pagePublicId: row.pagePublicId,
        sortIndex: random.nextInt(6),
        expectedElementRevision: row.revision,
      );
    },
    'move an agent to another page': (rows, opId) {
      final rowsHere = live(rows);
      if (rowsHere.isEmpty) return null;
      final row = pick(rowsHere);
      return ElementPatchOp(
        opId: opId,
        elementPublicId: row.publicId,
        expectedElementRevision: row.revision,
        pagePublicId: 'page-b',
      );
    },
    'delete an agent': (rows, opId) {
      final rowsHere = live(rows);
      if (rowsHere.isEmpty) return null;
      final row = pick(rowsHere);
      return ElementDeleteOp(
        opId: opId,
        elementPublicId: row.publicId,
        pagePublicId: row.pagePublicId,
        expectedElementRevision: row.revision,
      );
    },
    'add an agent': (rows, opId) {
      final id = 'new-${_fresh++}';
      return ElementAddOp(
        opId: opId,
        elementPublicId: id,
        pagePublicId: 'page-a',
        payload: agentPayload(id, {'type': 'raze'}),
        sortIndex: 3,
      );
    },
    'bring back a deleted agent': (rows, opId) =>
        switch (rows.element('ghost')) {
          final DeletedElement ghost when ghost.revision == 2 => ElementAddOp(
            opId: opId,
            elementPublicId: 'ghost',
            pagePublicId: 'page-a',
            payload: agentPayload('ghost', {'type': 'omen', 'caption': 'back'}),
            sortIndex: 2,
            expectedElementRevision: ghost.revision,
          ),
          _ => null,
        },
    'edit a lineup note': (rows, opId) => groupEdit(rows, opId, (data) {
      final links = [...(data['links']! as List).cast<Map<String, Object?>>()];
      if (links.isEmpty) return null;
      final at = random.nextInt(links.length);
      links[at] = {...links[at], 'notes': 'n${random.nextInt(9)}'};
      return {...data, 'links': links};
    }),
    'remove a lineup link': (rows, opId) => groupEdit(rows, opId, (data) {
      final links = [...(data['links']! as List).cast<Map<String, Object?>>()];
      if (links.length < 2) return null;
      links.removeAt(random.nextInt(links.length));
      return {...data, 'links': links};
    }),
    'add a lineup link': (rows, opId) => groupEdit(rows, opId, (data) {
      final origins = (data['origins']! as List).cast<Map<String, Object?>>();
      final landings = (data['landings']! as List).cast<Map<String, Object?>>();
      if (origins.isEmpty || landings.isEmpty) return null;
      return {
        ...data,
        'links': [
          ...(data['links']! as List),
          _link(
            'k-new-${_fresh++}',
            pick(origins)['id']! as String,
            pick(landings)['id']! as String,
          ),
        ],
      };
    }),
    'rewrite a lineup group whole': (rows, opId) {
      final row = group(rows);
      if (row == null) return null;
      final data = row.payload.data.toJson();
      return LineupGroupPatchOp(
        opId: opId,
        lineupPublicId: 'g1',
        expectedLineupRevision: row.revision,
        payload: row.payload.withData({
          ...data,
          'links': [
            for (final link
                in (data['links']! as List).cast<Map<String, Object?>>())
              {...link, 'notes': 'whole ${random.nextInt(9)}'},
          ],
        }),
      );
    },
    'reorder a lineup group': (rows, opId) {
      final row = group(rows);
      if (row == null) return null;
      return LineupGroupReorderOp(
        opId: opId,
        lineupPublicId: 'g1',
        pagePublicId: 'page-a',
        sortIndex: random.nextInt(4),
        expectedLineupRevision: row.revision,
      );
    },
    'delete a lineup group': (rows, opId) {
      final live = [
        for (final row in rows.lineupGroups)
          if (row is LiveLineupGroup) row,
      ];
      if (live.isEmpty) return null;
      final row = pick(live);
      return LineupGroupDeleteOp(
        opId: opId,
        lineupPublicId: row.publicId,
        pagePublicId: row.pagePublicId,
        expectedLineupRevision: row.revision,
      );
    },
    'bring back a deleted lineup group': (rows, opId) => switch (rows
        .lineupGroup('g0')) {
      final DeletedLineupGroup row when row.revision == 2 => LineupGroupAddOp(
        opId: opId,
        lineupPublicId: 'g0',
        pagePublicId: 'page-a',
        payload: _twoLinks('g0'),
        sortIndex: 1,
        expectedLineupRevision: row.revision,
      ),
      _ => null,
    },
    'add a lineup group with two links': (rows, opId) {
      final id = 'g-new-${_fresh++}';
      return LineupGroupAddOp(
        opId: opId,
        lineupPublicId: id,
        pagePublicId: 'page-a',
        payload: _twoLinks(id),
        sortIndex: 2,
      );
    },
    'remove the first link of a group': (rows, opId) {
      final groups = [
        for (final row in rows.lineupGroups)
          if (row case final LiveLineupGroup live
              when (live.payload.data['links']! as JsonList).length > 1)
            live,
      ];
      if (groups.isEmpty) return null;
      final row = pick(groups);
      final data = row.payload.data.toJson();
      return lineupEditOp(
        opId: opId,
        base: row,
        drawn: DrawnAt(row.revision),
        payload: row.payload.withData({
          ...data,
          'links': [...(data['links']! as List<Object?>).skip(1)],
        }),
        sortIndex: row.sortIndex,
        connection: Connection.live,
      );
    },
    'reverse the links of the group whole': (rows, opId) {
      final row = group(rows);
      if (row == null) return null;
      final data = row.payload.data.toJson();
      final links = (data['links']! as List<Object?>).reversed.toList();
      if (links.length < 2) return null;
      return LineupGroupPatchOp(
        opId: opId,
        lineupPublicId: 'g1',
        expectedLineupRevision: row.revision,
        payload: row.payload.withData({...data, 'links': links}),
      );
    },
    'rename the page': (rows, opId) {
      final row = rows.page('page-a')! as LivePage;
      return PagePatchOp(
        opId: opId,
        pagePublicId: 'page-a',
        expectedPageRevision: row.revision,
        name: 'Named ${random.nextInt(9)}',
        isAutoNamed: false,
      );
    },
    'switch the page side': (rows, opId) {
      final row = rows.page('page-a')! as LivePage;
      return PagePatchOp(
        opId: opId,
        pagePublicId: 'page-a',
        expectedPageRevision: row.revision,
        isAttack: !row.isAttack,
      );
    },
    'change the page settings': (rows, opId) {
      final row = rows.settingsOf('page-a')! as ReadablePageSettings;
      return PageSettingsPatchOp(
        opId: opId,
        pagePublicId: 'page-a',
        settings: PageSettings(
          agentSize: 1.0 + random.nextInt(4),
          abilitySize: 1,
          useNeutralTeamColors: random.nextBool(),
        ),
        expectedPageSettingsRevision: row.revision,
      );
    },
    'rename the strategy': (rows, opId) => StrategyPatchOp(
      opId: opId,
      expectedStrategyRevision: rows.strategy.revision,
      name: 'Strategy ${random.nextInt(9)}',
    ),
    'change the strategy theme': (rows, opId) => StrategyPatchOp(
      opId: opId,
      expectedStrategyRevision: rows.strategy.revision,
      themeProfile: random.nextBool()
          ? SetValue('profile-${random.nextInt(3)}')
          : const ClearValue(),
      themeOverridePalette: random.nextBool()
          ? const ClearValue()
          : SetValue(
              ThemePalette(
                base: '#${random.nextInt(9)}00',
                detail: '#111',
                highlight: '#222',
              ),
            ),
    ),
  };
}

Object? _itemsById(Object? json) => switch (json) {
  final Map<String, Object?> map => {
    for (final MapEntry(:key, :value) in map.entries)
      key: switch (value) {
        final List<Object?> items
            when items.isNotEmpty &&
                items.every((item) => item is Map && item['id'] is String) =>
          [...items.map(_itemsById)]..sort(
            (a, b) => ((a! as Map)['id'] as String).compareTo(
              (b! as Map)['id'] as String,
            ),
          ),
        _ => _itemsById(value),
      },
  },
  final List<Object?> list => [for (final item in list) _itemsById(item)],
  _ => json,
};

bool _isCleared(ElementKind kind, String field, Object? value) =>
    switch (laterField(kind, field)?.empty) {
      ClearedBy(value: final cleared) =>
        jsonEncode(cleared) == jsonEncode(value),
      NeverCleared() || null => false,
    };

typedef _Stored = Map<String, Map<String, Object?>>;

typedef _Pinned = ({String why, _Stored Function(_Stored rows) same});

Map<String, Object?> _map(Object? json) => json! as Map<String, Object?>;

_Stored _each(
  _Stored rows,
  Map<String, Object?> Function(String key, Map<String, Object?> row) change,
) => {
  for (final MapEntry(:key, :value) in rows.entries) key: change(key, value),
};

final List<_Pinned> _pinned = [
  (
    why: 'a revision and an updated time move forward with every write',
    same: (rows) => _each(
      rows,
      (_, row) => {...row}
        ..remove('revision')
        ..remove('updatedAt'),
    ),
  ),
  (
    why:
        'a page saved before isAutoNamed holds false after an undo, which '
        'the server reads as the same',
    same: (rows) => _each(
      rows,
      (key, row) =>
          key.startsWith('page ') ? {'isAutoNamed': false, ...row} : row,
    ),
  ),
  (
    why: 'settings never set hold the app defaults after an undo',
    same: (rows) => _each(
      rows,
      (key, row) => key.startsWith('settings ')
          ? {'settings': defaultSettings.toJson(), ...row}
          : row,
    ),
  ),
  (
    why:
        'a later field at its cleared value is the same as no field, since '
        'the server keeps it once set',
    same: (rows) => _each(rows, (key, row) {
      if (!key.startsWith('element ')) return row;
      final payload = _map(row['payload']);
      final kind = ElementKind.named(payload['kind'])!;
      return {
        ...row,
        'payload': {
          ...payload,
          'data': {
            for (final MapEntry(:key, :value) in _map(payload['data']).entries)
              if (!_isCleared(kind, key, value)) key: value,
          },
        },
      };
    }),
  ),
  (
    why: 'a lineup item put back by a merge comes back last',
    same: (rows) => _each(
      rows,
      (key, row) => key.startsWith('group ') ? _map(_itemsById(row)) : row,
    ),
  ),
  (
    why: 'a deleted row holds whatever payload the last write left',
    same: (rows) => _each(
      rows,
      (_, row) => row['deleted'] == true ? ({...row}..remove('payload')) : row,
    ),
  ),
];

_Stored _stored(StrategyRowSet rows) => {
  'strategy': _map(rows.strategy.toJson()),
  for (final row in rows.pages) 'page ${row.key.id}': _map(row.toJson()),
  for (final row in rows.settings) 'settings ${row.key.id}': _map(row.toJson()),
  for (final row in rows.elements) 'element ${row.key.id}': _map(row.toJson()),
  for (final row in rows.lineupGroups)
    'group ${row.key.id}': _map(row.toJson()),
};

_Stored _compared(_Stored rows, Set<String> startKeys) => _pinned.fold({
  for (final MapEntry(:key, :value) in rows.entries)
    if (startKeys.contains(key) || value['deleted'] != true) key: value,
}, (rows, pinned) => pinned.same(rows));

void main() {
  test(
    'any run of edits to one page, undone in reverse with each undo built when it is used, '
    'puts every row back, and redone puts it back to the end',
    () {
      final random = Random(658);
      final edits = _Edits(random);
      final used = <String>{};
      var runs = 0;
      var undone = 0;
      var nothing = 0;
      while (runs < 3000) {
        final session = Session(_start(legacy: random.nextBool()));
        final start = _stored(session.rows);
        final startKeys = start.keys.toSet();
        final names = <String>[];
        final undos = <Undo>[];
        final length = 1 + random.nextInt(4);
        var attempts = 0;
        while (undos.length < length && attempts++ < 40) {
          final name = edits.pick(edits.all.keys.toList());
          final op = edits.all[name]!(
            session.rows,
            'edit-$runs-${names.length}',
          );
          if (op == null) continue;
          switch (session.attempt(op)) {
            case final OpApplied applied:
              session.rows = session.rows.withRows(applied.rows);
              undos.add(applied.undo);
              names.add(name);
              used.add(name);
            case OpUnchanged() || OpRefused():
              continue;
          }
        }
        final where = names.join(', then ');
        final end = _stored(session.rows);
        final redos = <Undo>[];
        for (final undo in undos.reversed) {
          final StrategyOp op;
          switch (session.buildUndoOf(
            OpApplied(writes: const [], undo: undo),
          )) {
            case UndoReady(op: final ready):
              op = ready;
            case NothingToUndo():
              nothing++;
              continue;
            case final other:
              fail('$where: undo built $other');
          }
          switch (session.attempt(op)) {
            case final OpApplied applied:
              session.rows = session.rows.withRows(applied.rows);
              redos.add(applied.undo);
              undone++;
            case final other:
              fail('$where: undo ${op.opId} gave ${describe(other)}');
          }
        }
        expect(
          _compared(_stored(session.rows), startKeys),
          _compared(start, startKeys),
          reason: '$where, undone',
        );
        for (final redo in redos.reversed) {
          final op = switch (session.buildUndoOf(
            OpApplied(writes: const [], undo: redo),
          )) {
            UndoReady(:final op) => op,
            final other => fail('$where: redo built $other'),
          };
          switch (session.attempt(op)) {
            case final OpApplied applied:
              session.rows = session.rows.withRows(applied.rows);
            case final other:
              fail('$where: redo ${op.opId} gave ${describe(other)}');
          }
        }
        expect(
          _compared(_stored(session.rows), startKeys),
          _compared(end, startKeys),
          reason: '$where, redone',
        );
        runs++;
      }
      expect(used, edits.all.keys.toSet());
      expect(undone, greaterThan(5000));
      expect(nothing, lessThan(undone ~/ 50));
    },
  );
}
