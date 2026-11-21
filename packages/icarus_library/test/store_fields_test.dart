import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

const _probe = '~probe';

Object? _probed(Object? json, String path) => switch (json) {
  final Map<String, Object?> map => {
    for (final MapEntry(:key, :value) in map.entries)
      key: _probed(value, '$path/$key'),
    _probe: path,
  },
  final List<Object?> list => [
    for (final (index, item) in list.indexed) _probed(item, '$path/$index'),
  ],
  _ => json,
};

Set<String> _probesIn(Object? json) => switch (json) {
  final Map<String, Object?> map => {
    if (map[_probe] case final String path) path,
    for (final value in map.values) ..._probesIn(value),
  },
  final List<Object?> list => {for (final item in list) ..._probesIn(item)},
  _ => const {},
};

enum Fate { kept, replaced }

final class Replaced {
  const Replaced(this.op, this.key, this.under);

  final String op;
  final String key;
  final String under;

  bool covers(String op, String key, String path) =>
      op == this.op &&
      key == this.key &&
      (path == under || path.startsWith('$under/'));
}

final _jett = elementName('page-a', 'jett');

final _table = [
  Replaced('pageContent.patch', settingsName('page-a'), '/settings'),
  Replaced('strategy.patch a palette', 'strategy', '/themeOverridePalette'),
  Replaced('element.patch', _jett, '/payload/data/position'),
  Replaced('element.patch whole', _jett, '/payload'),
  Replaced(
    'element.add over a deleted element',
    elementName('page-a', 'ghost'),
    '/payload',
  ),
  Replaced('lineup.patch', lineupName('page-a', 'g1'), '/payload'),
  Replaced(
    'lineup.patch merging a link',
    lineupName('page-a', 'g1'),
    '/payload/data/links/0',
  ),
  Replaced(
    'lineup.add over a deleted group',
    lineupName('page-b', 'g0'),
    '/payload',
  ),
  Replaced(
    'lineup.patch removing the first of three links',
    lineupName('page-c', 'g4'),
    '/payload/data/links/0',
  ),
  Replaced(
    'lineup.patch removing the first of three links',
    lineupName('page-c', 'g4'),
    '/payload/data/origins/0',
  ),
];

const _undoneOtherwise = <String, Undo>{
  'page.delete': UndoByRestoringPage('page-a'),
  'pageContent.patch on settings never set': UndoByWritingDefaultSettings(
    pagePublicId: 'page-c',
    expectedPageSettingsRevision: 2,
  ),
};

final _undoneLast = {
  'lineup.patch removing the first of three links': lineupName('page-c', 'g4'),
};

Object? _itemsById(Object? json) => switch (json) {
  final Map<String, Object?> map => {
    for (final MapEntry(:key, :value) in map.entries)
      key: switch (value) {
        final List<Object?> items
            when items.every((item) => item is Map && item['id'] is String) =>
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

List<Object?> _linkIds(Map<String, Object?>? row) => [
  for (final link
      in (((row!['payload']! as Map)['data']! as Map)['links']! as List))
    (link! as Map)['id'],
];

final _undoneAutoNamed = {
  'page.patch naming a page saved before isAutoNamed': pageName('page-c'),
};

final _manyLinks = LineupGroupPayload(
  payloadVersion: 1,
  data: {
    'id': 'g4',
    'origins': [origin('g4-o1'), origin('g4-o2')],
    'landings': [landing('g4-l1'), landing('g4-l2')],
    'links': [
      for (final (id, from, to) in [
        ('g4-k1', 'g4-o1', 'g4-l1'),
        ('g4-k2', 'g4-o2', 'g4-l1'),
        ('g4-k3', 'g4-o2', 'g4-l2'),
      ])
        {'id': id, 'originId': from, 'landingId': to, 'notes': id},
    ],
  },
);

final _deletedAgainHolding = {
  'element.add over a deleted element': (
    elementName('page-a', 'ghost'),
    jsonDecode(jsonEncode(agent('ghost').payload.toJson())),
  ),
  'lineup.add over a deleted group': (
    lineupName('page-b', 'g0'),
    jsonDecode(jsonEncode(lineupPayload('g0').toJson())),
  ),
};

Map<String, Object?>? _withoutClock(String? stored) => switch (stored) {
  null => null,
  final text =>
    {...jsonDecode(text) as Map<String, Object?>}
      ..remove('revision')
      ..remove('updatedAt'),
};

Fate _fateOf(String op, String key, String path) =>
    _table.any((row) => row.covers(op, key, path)) ? Fate.replaced : Fate.kept;

Map<String, StrategyOp> _ops() => {
  ...everyOpType(),
  'strategy.patch a palette': const StrategyPatchOp(
    opId: 'op-palette',
    expectedStrategyRevision: 1,
    themeOverridePalette: SetValue(
      ThemePalette(base: '#111', detail: '#222', highlight: '#333'),
    ),
  ),
  'element.patch whole': ElementPatchOp(
    opId: 'op-whole',
    elementPublicId: 'jett',
    expectedElementRevision: 1,
    payload: agentPayload('jett', {
      'type': 'jett',
      'position': {'dx': 1, 'dy': 2},
    }),
  ),
  'element.add over a deleted element': ElementAddOp(
    opId: 'op-restore',
    elementPublicId: 'ghost',
    pagePublicId: 'page-a',
    payload: agent('ghost').payload,
    sortIndex: 0,
    expectedElementRevision: 2,
  ),
  'lineup.patch merging a link': LineupGroupPatchOp(
    opId: 'op-link',
    lineupPublicId: 'g1',
    expectedLineupRevision: 1,
    payload: lineupPayload('g1', notes: 'merged'),
    merge: FieldMerge(fields: ['links/g1-k']),
  ),
  'page.patch naming a page saved before isAutoNamed': const PagePatchOp(
    opId: 'op-auto-named',
    pagePublicId: 'page-c',
    expectedPageRevision: 1,
    name: 'Retake C',
    isAutoNamed: false,
  ),
  'pageContent.patch on settings never set': const PageSettingsPatchOp(
    opId: 'op-first-settings',
    pagePublicId: 'page-c',
    settings: defaultSettings,
    expectedPageSettingsRevision: 1,
  ),
  'lineup.patch removing the first of three links': LineupGroupPatchOp(
    opId: 'op-unlink',
    lineupPublicId: 'g4',
    expectedLineupRevision: 1,
    payload: _manyLinks.withData({
      ..._manyLinks.data.toMap(),
      'links': [...(_manyLinks.data['links']! as JsonList).skip(1)],
    }),
    merge: FieldMerge(fields: ['links/g4-k1']),
  ),
  'lineup.add over a deleted group': LineupGroupAddOp(
    opId: 'op-regroup',
    lineupPublicId: 'g0',
    pagePublicId: 'page-b',
    payload: lineupPayload('g0'),
    sortIndex: 0,
    expectedLineupRevision: 2,
  ),
};

StrategyRowSet _fixture() {
  final sample = sampleStrategy();
  final jett = agent('jett');
  return StrategyRowSet(
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
      ...sample.pages,
      ConfirmedTrashedPage(
        publicId: 'page-d',
        strategyPublicId: strategyId,
        name: 'Old retake',
        sortIndex: 3,
        isAttack: true,
        revision: 1,
        deletedAt: strategyCreatedAt,
        deletedBy: const DeletedByName('coach'),
      ),
    ],
    settings: [
      for (final row in sample.settings)
        if (row.pagePublicId != 'page-c') row,
      ReadablePageSettings(pagePublicId: 'page-c', revision: 1),
    ],
    elements: [
      for (final row in sample.elements)
        if (row.publicId != 'jett') row,
      LiveElement(
        publicId: 'jett',
        pagePublicId: 'page-a',
        payload: jett.payload.withData({
          ...jett.payload.data.toMap(),
          'caption': 'entry',
          pictureIdField: 'picture-1',
        }),
        sortIndex: 0,
        revision: 1,
      ),
      DeletedElement(
        publicId: 'ghost',
        pagePublicId: 'page-a',
        payload: agent('ghost').payload,
        sortIndex: 0,
        revision: 2,
      ),
    ],
    lineupGroups: [
      ...sample.lineupGroups,
      lineupGroup('g3', pageId: 'page-b', strategy: strategyId),
      LiveLineupGroup(
        strategyPublicId: strategyId,
        publicId: 'g4',
        pagePublicId: 'page-c',
        payload: _manyLinks,
        sortIndex: 0,
        revision: 1,
      ),
      DeletedLineupGroup(
        strategyPublicId: strategyId,
        publicId: 'g0',
        pagePublicId: 'page-b',
        payload: lineupPayload('g0'),
        sortIndex: 0,
        revision: 2,
      ),
    ],
  );
}

void main() {
  late Contents probed;

  setUpAll(() async {
    final storage = MemoryStorage();
    final store = await openStore(MemoryEngine(storage));
    savedValue(await store.editLibrary([AddStrategy(_fixture())]));
    await store.close();
    final area = {
      for (final MapEntry(:key, :value)
          in storage.contents[sampleArea]!.entries)
        key: jsonEncode(_probed(jsonDecode(value), '')),
    };
    probed = {...storage.contents, sampleArea: area};
  });

  for (final MapEntry(key: name, value: op) in _ops().entries) {
    test(
      '$name keeps or replaces each stored field as the table says',
      () async {
        final disk = MemoryStorage(probed);
        final store = await openStore(MemoryEngine(disk));
        final committed = savedValue(await store.commit(strategyId, op));
        await store.close();
        final after = disk.contents[sampleArea]!;
        final moved = {
          for (final write in committed.change.writes)
            if (write case RowChanged(:final before, :final after)
                when before is ElementRow &&
                    after is ElementRow &&
                    before.pagePublicId != after.pagePublicId)
              elementName(before.pagePublicId, before.publicId): elementName(
                after.pagePublicId,
                after.publicId,
              ),
        };
        var checked = 0;
        for (final MapEntry(:key, :value) in probed[sampleArea]!.entries) {
          final now = after[moved[key] ?? key];
          if (now == null) fail('$name dropped the row at $key');
          final kept = _probesIn(jsonDecode(now));
          for (final path in _probesIn(jsonDecode(value))) {
            checked++;
            expect(
              kept.contains(path) ? Fate.kept : Fate.replaced,
              _fateOf(name, key, path),
              reason: '$name, $key, $path',
            );
          }
        }
        expect(checked, greaterThan(40));
        if (name == 'element.patch whole') {
          final data =
              ((jsonDecode(after[_jett]!) as Map)['payload'] as Map)['data']
                  as Map<String, Object?>;
          expect(data[pictureIdField], 'picture-1');
          for (final later in laterElementFields) {
            if (later.kinds.contains(ElementKind.agent)) {
              expect(data[later.field], 'entry', reason: later.field);
            }
          }
        }
      },
    );
  }

  test('a page copy carries every stored field of what it copies', () async {
    final disk = MemoryStorage(probed);
    final store = await openStore(MemoryEngine(disk));
    final committed = savedValue(
      await store.commit(strategyId, everyOpType()['page.add copying a page']!),
    );
    await store.close();
    final copied = [
      for (final write in committed.change.writes)
        if (write case RowAdded(:final after))
          if (after
              case ElementRow(pagePublicId: 'page-copy') ||
                  LineupGroupRow(pagePublicId: 'page-copy'))
            after,
    ];
    expect(copied.whereType<ElementRow>(), isNotEmpty);
    expect(copied.whereType<LineupGroupRow>(), isNotEmpty);
    for (final row in copied) {
      final probes = _probesIn(jsonDecode(jsonEncode(row.toJson())));
      expect(probes, containsAll(['', '/payload', '/payload/data']));
    }
  });

  for (final MapEntry(key: name, value: op) in _ops().entries) {
    test('undoing $name stores again exactly what was stored', () async {
      final disk = MemoryStorage(probed);
      final store = await openStore(MemoryEngine(disk));
      final committed = savedValue(await store.commit(strategyId, op));
      switch (committed.undo) {
        case UndoWithOp(op: final undo):
          expect(_undoneOtherwise[name], isNull, reason: name);
          savedValue(await store.commit(strategyId, undo));
        case final other:
          expect(other, _undoneOtherwise[name], reason: name);
          return;
      }
      await store.close();
      final after = disk.contents[sampleArea]!;
      for (final MapEntry(:key, :value) in probed[sampleArea]!.entries) {
        final (now, was) = (_withoutClock(after[key]), _withoutClock(value));
        if (_deletedAgainHolding[name] case (
          final row,
          final added,
        ) when row == key) {
          expect(now, {...?was, 'payload': added}, reason: '$name, $key');
        } else if (_undoneLast[name] == key) {
          expect(_itemsById(now), _itemsById(was), reason: '$name, $key');
          expect(_linkIds(now).last, 'g4-k1', reason: '$name, $key');
        } else if (_undoneAutoNamed[name] == key) {
          expect(now, {...?was, 'isAutoNamed': false}, reason: '$name, $key');
        } else {
          expect(now, was, reason: '$name, $key');
        }
      }
    });
  }

  for (final MapEntry(key: row, value: (key, edits))
      in _editsOfOneRow.entries) {
    for (final sequence in _sequences(edits.length)) {
      final names = [for (final at in sequence) edits[at].$1];
      test(
        'on $row, ${names.join(', then ')}, undone in reverse order, stores the row again',
        () async {
          final disk = MemoryStorage(probed);
          final store = await openStore(MemoryEngine(disk));
          final undos = <StrategyOp>[];
          for (final (step, at) in sequence.indexed) {
            final current =
                jsonDecode(disk.contents[sampleArea]![key]!)
                    as Map<String, Object?>;
            switch (await store.commit(
              strategyId,
              edits[at].$2(current, 'step-$step'),
            )) {
              case Saved(value: Committed(undo: UndoWithOp(:final op))):
                undos.add(op);
              case NothingToSave():
                break;
              case final other:
                fail('step $step: ${describeSaving(other)}');
            }
          }
          for (final undo in undos.reversed) {
            final undone = await store.commit(strategyId, undo);
            expect(
              undone,
              isA<Saved<Committed, CommitRefusal>>(),
              reason: '${undo.opId}: ${describeSaving(undone)}',
            );
          }
          await store.close();
          final now = _withoutClock(disk.contents[sampleArea]![key]);
          final was = _withoutClock(probed[sampleArea]![key]);
          expect(_itemsById(now), _itemsById(was));
        },
      );
    }
  }
}

List<List<int>> _sequences(int edits) => [
  for (var a = 0; a < edits; a++)
    for (var b = 0; b < edits; b++) ...[
      [a, b],
      for (var c = 0; c < edits; c++) [a, b, c],
    ],
];

typedef _Edit = StrategyOp Function(Map<String, Object?> row, String opId);

int _revisionOf(Map<String, Object?> row) => row['revision']! as int;

Map<String, Object?> _dataOf(Map<String, Object?> row) => {
  ...((row['payload']! as Map)['data']! as Map).cast<String, Object?>(),
};

LineupGroupPatchOp _linkEdit(
  Map<String, Object?> row,
  String opId,
  String linkId,
  Map<String, Object?>? Function(Map<String, Object?> link) change,
) {
  final data = _dataOf(row);
  final links = [
    for (final link in (data['links']! as List).cast<Map<String, Object?>>())
      if (link['id'] == linkId) ?change(link) else link,
  ];
  return LineupGroupPatchOp(
    opId: opId,
    lineupPublicId: 'g4',
    expectedLineupRevision: _revisionOf(row),
    payload: _manyLinks.withData({...data, 'links': links}),
    merge: FieldMerge(fields: ['links/$linkId']),
  );
}

final _editsOfOneRow = <String, (String, List<(String, _Edit)>)>{
  'a lineup group': (
    lineupName('page-c', 'g4'),
    [
      (
        'remove the first link',
        (row, opId) => _linkEdit(row, opId, 'g4-k1', (_) => null),
      ),
      (
        'edit the note of the second link',
        (row, opId) =>
            _linkEdit(row, opId, 'g4-k2', (link) => {...link, 'notes': opId}),
      ),
      (
        'edit the note of the third link',
        (row, opId) =>
            _linkEdit(row, opId, 'g4-k3', (link) => {...link, 'notes': opId}),
      ),
    ],
  ),
  'an agent': (
    _jett,
    [
      for (final (what, field, value) in [
        ('move it', 'position', <String, Object?>{'dx': 300, 'dy': 400}),
        ('caption it', 'caption', 'retake'),
      ])
        (
          what,
          (row, opId) => ElementPatchOp(
            opId: opId,
            elementPublicId: 'jett',
            expectedElementRevision: _revisionOf(row),
            payload: agentPayload('jett', {..._dataOf(row), field: value}),
            merge: FieldMerge(fields: [field]),
          ),
        ),
    ],
  ),
};
