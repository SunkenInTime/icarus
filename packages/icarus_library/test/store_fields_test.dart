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

const _jett = 'content/page-a/element/jett';

const _table = [
  Replaced('pageContent.patch', 'settings/page-a', '/settings'),
  Replaced('strategy.patch a palette', 'strategy', '/themeOverridePalette'),
  Replaced('element.patch', _jett, '/payload/data/position'),
  Replaced('element.patch whole', _jett, '/payload'),
  Replaced(
    'element.add over a deleted element',
    'content/page-a/element/ghost',
    '/payload',
  ),
  Replaced('lineup.patch', 'content/page-a/lineup/g1', '/payload'),
  Replaced(
    'lineup.patch merging a link',
    'content/page-a/lineup/g1',
    '/payload/data/links/0',
  ),
  Replaced(
    'lineup.add over a deleted group',
    'content/page-b/lineup/g0',
    '/payload',
  ),
];

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
    pages: sample.pages,
    settings: sample.settings,
    elements: [
      for (final row in sample.elements)
        if (row.publicId != 'jett') row,
      LiveElement(
        publicId: 'jett',
        pagePublicId: 'page-a',
        payload: jett.payload.withData({
          ...jett.payload.data,
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
              'content/${before.pagePublicId}/element/${before.publicId}':
                  'content/${after.pagePublicId}/element/${after.publicId}',
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
        if (write case RowAdded(
          after: final ElementRow row,
        ) when row.pagePublicId == 'page-copy')
          row,
    ];
    expect(copied, isNotEmpty);
    for (final row in copied) {
      final probes = _probesIn(row.toJson());
      expect(probes, containsAll(['', '/payload', '/payload/data']));
    }
  });
}
