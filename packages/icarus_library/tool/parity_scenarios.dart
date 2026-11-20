import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:icarus_library/icarus_library.dart';

import 'merge_stories.dart';

const strategyId = 's1';

void main(List<String> args) {
  if (args.length != 4) {
    stderr.writeln(
      'usage: parity_scenarios <first seed> <seeds> <steps> <out>',
    );
    exitCode = 64;
    return;
  }
  final first = int.parse(args[0]);
  final seeds = int.parse(args[1]);
  final steps = int.parse(args[2]);
  final scenarios = [
    for (var seed = first; seed < first + seeds; seed++) _scenario(seed, steps),
    for (final story in mergeStories()) _story(story),
  ];
  File(args[3]).writeAsStringSync(jsonEncode(scenarios));
}

Map<String, Object?> _rowsJson(StrategyRowSet rows) => {
  'strategy': rows.strategy.toJson(),
  'pages': [for (final r in rows.pages) r.toJson()],
  'settings': [for (final r in rows.settings) r.toJson()],
  'elements': [for (final r in rows.elements) r.toJson()],
  'lineupGroups': [for (final r in rows.lineupGroups) r.toJson()],
};

Map<String, Object?> _story(MergeStory story) {
  var rows = storyRows;
  final predicted = <Map<String, Object?>>[];
  for (final op in story.ops) {
    final result = applyOp(rows, op);
    if (result is OpApplied) rows = rows.withRows(result.rows);
    predicted.add({...outcomeJson(result), 'rows': _rowsJson(rows)});
  }
  return {
    'story': story.name,
    'initial': _rowsJson(storyRows),
    'ops': [for (final op in story.ops) op.toJson()],
    'predicted': predicted,
    'outcomes': story.outcomes,
    'expected': story.expected,
  };
}

List<Map<String, Object?>> _items(Map<String, Object?> data, String key) => [
  for (final item in data[key] as List<Object?>? ?? const [])
    if (item is Map<String, Object?>) item,
];

Map<String, Object?> _origin(String id) => {
  'id': id,
  'agent': {'type': 'sova', 'lineUpID': id},
};

Map<String, Object?> _landing(String id) => {
  'id': id,
  'ability': {'type': 'recon', 'lineUpID': id},
};

Map<String, Object?> _link(String id, String o, String l, String notes) => {
  'id': id,
  'originId': o,
  'landingId': l,
  'notes': notes,
};

LineupGroupPayload _group(String id, String n) => LineupGroupPayload(
  payloadVersion: 1,
  data: {
    'id': id,
    'origins': [_origin('o$n')],
    'landings': [_landing('l$n')],
    'links': [_link('k$n', 'o$n', 'l$n', '')],
  },
);

Map<String, Object?> _scenario(int seed, int steps) {
  final rng = Random(seed);
  var fresh = 0;
  String newId() => 'n${fresh++}';
  T pick<T>(List<T> list) => list[rng.nextInt(list.length)];
  bool chance(double p) => rng.nextDouble() < p;

  ElementPayload payload(String id, ElementKind kind, int n) => ElementPayload(
    kind: kind,
    payloadVersion: 1,
    data: {
      'id': id,
      'elementType': kind.name,
      'position': {'x': n, 'y': n},
      'isAlly': n.isEven,
      'rotation': n * 10,
      'length': 5,
      if (n.isOdd) 'caption': 'note $n',
    },
  );

  final pageIds = ['p0', 'p1', 'p2'];
  var rows = StrategyRowSet(
    strategy: const StrategyRow(
      publicId: strategyId,
      name: 'Retake',
      mapData: 'ascent',
      revision: 1,
    ),
    pages: [
      for (final (i, id) in pageIds.indexed)
        LivePage(
          publicId: id,
          strategyPublicId: strategyId,
          name: i < 2 ? 'Page ${i + 1}' : 'Exec',
          isAutoNamed: i < 2 ? true : false,
          sortIndex: i,
          isAttack: true,
          revision: 1,
        ),
    ],
    settings: [
      for (final id in pageIds)
        PageSettingsRow(
          pagePublicId: id,
          settings: const PageSettings(
            agentSize: 1,
            abilitySize: 1,
            useNeutralTeamColors: false,
          ),
          revision: 1,
        ),
    ],
    elements: [
      for (var i = 0; i < 5; i++)
        LiveElement(
          publicId: 's$seed-e$i',
          pagePublicId: pageIds[i % 2],
          payload: payload(
            's$seed-e$i',
            i.isEven ? ElementKind.agent : ElementKind.ability,
            i,
          ),
          sortIndex: i,
          revision: 1,
        ),
    ],
    lineupGroups: [
      LiveLineupGroup(
        strategyPublicId: strategyId,
        publicId: 'g0',
        pagePublicId: 'p0',
        payload: _group('g0', '0'),
        sortIndex: 0,
        revision: 1,
      ),
      LiveLineupGroup(
        strategyPublicId: strategyId,
        publicId: 'g1',
        pagePublicId: 'p1',
        payload: _group('g1', '1'),
        sortIndex: 0,
        revision: 1,
      ),
    ],
  );
  final initial = _rowsJson(rows);
  final history = <String, List<Map<String, Object?>>>{};
  for (final element in rows.elements) {
    history[element.publicId] = [(element as LiveElement).payload.data];
  }
  final groupHistory = <String, List<Map<String, Object?>>>{
    for (final g in rows.lineupGroups) g.publicId: [g.payload.data],
  };

  int rev(int current) => chance(0.85) ? current : current + pick([-1, 1]);
  List<String> allPages() => [
    ...rows.pages.map((p) => p.publicId),
    'p-missing',
  ];
  List<String> livePages() => [
    for (final p in rows.pages)
      if (p is LivePage) p.publicId,
  ];
  List<String> elementIds() => [
    ...rows.elements.map((e) => e.publicId),
    'e-missing',
  ];
  List<String> groupIds() => [
    ...rows.lineupGroups.map((g) => g.publicId),
    'g-missing',
  ];
  const settingsChoices = [
    PageSettings(agentSize: 1, abilitySize: 1, useNeutralTeamColors: false),
    PageSettings(agentSize: 1.5, abilitySize: 0.75, useNeutralTeamColors: true),
  ];

  StrategyOp elementPatch(String opId) {
    final id = pick(elementIds());
    final row = rows.element(id);
    final current = switch (row) {
      ReadableElementRow(:final payload) => payload,
      _ => payload(id, ElementKind.agent, 3),
    };
    final data = {...current.data};
    final changed = <String>[];
    void change(String key, Object? value) {
      data[key] = value;
      changed.add(key);
    }

    if (chance(0.6)) {
      change('position', {'x': rng.nextInt(9), 'y': rng.nextInt(9)});
    }
    if (chance(0.4)) change('isAlly', chance(0.5));
    if (chance(0.3)) {
      change('rotation', rng.nextInt(4) * 90);
      change('length', rng.nextInt(3) + 4);
    }
    if (chance(0.25)) {
      if (chance(0.5)) {
        data.remove('caption');
        changed.add('caption');
      } else {
        change('caption', 'c${rng.nextInt(3)}');
      }
    }
    if (chance(0.05)) change('type', 'flipped');
    var kind = current.kind;
    if (chance(0.04)) {
      kind = kind == ElementKind.agent
          ? ElementKind.ability
          : ElementKind.agent;
      data['elementType'] = kind.name;
    }
    final sent = ElementPayload(
      kind: kind,
      payloadVersion: chance(0.05) ? 2 : current.payloadVersion,
      data: data,
    );
    final withPayload = chance(0.9);
    final sortIndex = chance(0.3) ? rng.nextInt(6) : null;
    FieldMerge? merge;
    if (chance(0.6)) {
      final fields = [...changed];
      if (sortIndex != null && chance(0.5)) fields.add('@sortIndex');
      if (chance(0.03)) fields.add(fields.isEmpty ? 'x' : fields.first);
      Map<String, Object?>? base;
      if (chance(0.35)) {
        final older = pick(history[id] ?? [current.data]);
        base = {
          for (final f in fields)
            if (f == '@sortIndex')
              if (chance(0.7))
                f: (row is ReadableElementRow ? row.sortIndex : 0)
              else
                f: rng.nextInt(6)
            else if (older.containsKey(f))
              f: older[f],
        };
      }
      merge = FieldMerge(fields: fields, base: base);
    }
    return ElementPatchOp(
      opId: opId,
      elementPublicId: id,
      expectedElementRevision: rev(
        row is ReadableElementRow ? row.revision : 1,
      ),
      payload: withPayload ? sent : null,
      sortIndex: sortIndex,
      pagePublicId: chance(0.15) ? pick(allPages()) : null,
      merge: merge,
    );
  }

  LineupGroupPayload editedGroup(LineupGroupRow row, List<String> fields) {
    final data = row.payload.data;
    final origins = [
      ...(data['origins']! as List<Object?>).cast<Map<String, Object?>>(),
    ];
    final landings = [
      ...(data['landings']! as List<Object?>).cast<Map<String, Object?>>(),
    ];
    final links = [
      ...(data['links']! as List<Object?>).cast<Map<String, Object?>>(),
    ];
    final roll = rng.nextInt(3);
    if (roll == 0 || links.isEmpty) {
      final n = newId();
      final useOrigin = chance(0.5) && origins.isNotEmpty;
      final originId = useOrigin ? pick(origins)['id']! as String : 'o$n';
      if (!useOrigin) {
        origins.add(_origin(originId));
        fields.add('origins/$originId');
      }
      landings.add(_landing('l$n'));
      fields.add('landings/l$n');
      links.add(_link('k$n', originId, 'l$n', ''));
      fields.add('links/k$n');
    } else if (roll == 1) {
      final i = rng.nextInt(links.length);
      links[i] = {...links[i], 'notes': 'n${rng.nextInt(4)}'};
      fields.add('links/${links[i]['id']}');
    } else {
      final i = rng.nextInt(links.length);
      final gone = links.removeAt(i);
      fields.add('links/${gone['id']}');
      final usedO = {for (final l in links) l['originId']};
      final usedL = {for (final l in links) l['landingId']};
      for (final o in [...origins]) {
        if (!usedO.contains(o['id'])) {
          origins.remove(o);
          fields.add('origins/${o['id']}');
        }
      }
      for (final l in [...landings]) {
        if (!usedL.contains(l['id'])) {
          landings.remove(l);
          fields.add('landings/${l['id']}');
        }
      }
    }
    return LineupGroupPayload(
      payloadVersion: 1,
      data: {...data, 'origins': origins, 'landings': landings, 'links': links},
    );
  }

  StrategyOp staleLineupMerge(String opId) {
    final id = pick(groupIds());
    final row = rows.lineupGroup(id);
    if (row == null) return elementPatch(opId);
    final older = pick(groupHistory[id] ?? [row.payload.data]);
    final origins = _items(older, 'origins');
    if (origins.isEmpty) return elementPatch(opId);
    final n = newId();
    final originId = pick(origins)['id']! as String;
    return LineupGroupPatchOp(
      opId: opId,
      lineupPublicId: id,
      expectedLineupRevision: row.revision,
      payload: LineupGroupPayload(
        payloadVersion: 1,
        data: {
          ...older,
          'landings': [..._items(older, 'landings'), _landing('l$n')],
          'links': [
            ..._items(older, 'links'),
            _link('k$n', originId, 'l$n', ''),
          ],
        },
      ),
      merge: FieldMerge(fields: ['landings/l$n', 'links/k$n']),
    );
  }

  StrategyOp nextOp(String opId) {
    switch (rng.nextInt(16)) {
      case 14:
      case 15:
        return staleLineupMerge(opId);
      case 0:
        return StrategyPatchOp(
          opId: opId,
          expectedStrategyRevision: rev(rows.strategy.revision),
          name: chance(0.4) ? 'S${rng.nextInt(3)}' : null,
          mapData: chance(0.2) ? pick(['ascent', 'bind']) : null,
          themeProfile: pick<ValueEdit<String>>([
            const KeepValue(),
            SetValue(pick(['ember', 'dusk'])),
            const ClearValue(),
          ]),
          themeOverridePalette: pick<ValueEdit<ThemePalette>>([
            const KeepValue(),
            const SetValue(
              ThemePalette(base: '#000', detail: '#111', highlight: '#222'),
            ),
            const ClearValue(),
          ]),
        );
      case 1:
        final existing = chance(0.2);
        return PageAddOp(
          opId: opId,
          pagePublicId: existing ? pick(allPages()) : 'p${newId()}',
          sortIndex: rng.nextInt(livePages().length + 2),
          expectedStrategyRevision: rev(rows.strategy.revision),
          name: chance(0.7) ? 'Page ${rng.nextInt(5) + 1}' : null,
          isAutoNamed: chance(0.7) ? chance(0.6) : null,
          isAttack: chance(0.5) ? chance(0.5) : null,
          settings: chance(0.8) ? pick(settingsChoices) : null,
        );
      case 2:
        final id = pick(allPages());
        return PagePatchOp(
          opId: opId,
          pagePublicId: id,
          expectedPageRevision: rev(rows.page(id)?.revision ?? 1),
          name: chance(0.5) ? 'Name ${rng.nextInt(3)}' : null,
          isAutoNamed: chance(0.4) ? chance(0.5) : null,
          isAttack: chance(0.4) ? chance(0.5) : null,
        );
      case 3:
        if (chance(0.7)) return elementPatch(opId);
        return PageDeleteOp(
          opId: opId,
          pagePublicId: pick(allPages()),
          expectedStrategyRevision: rev(rows.strategy.revision),
        );
      case 4:
        return PageReorderOp(
          opId: opId,
          pagePublicId: pick(allPages()),
          sortIndex: rng.nextInt(livePages().length + 1),
          expectedStrategyRevision: rev(rows.strategy.revision),
        );
      case 5:
        final id = pick(allPages());
        return PageSettingsPatchOp(
          opId: opId,
          pagePublicId: id,
          settings: pick(settingsChoices),
          expectedPageSettingsRevision: rev(rows.settingsOf(id)?.revision ?? 1),
        );
      case 6:
        final existing = chance(0.4);
        final id = existing ? pick(elementIds()) : 's$seed-${newId()}';
        final row = rows.element(id);
        final p = row is ReadableElementRow && chance(0.5)
            ? row.payload
            : payload(
                id,
                pick([ElementKind.agent, ElementKind.ability]),
                rng.nextInt(4),
              );
        return ElementAddOp(
          opId: opId,
          elementPublicId: id,
          pagePublicId: chance(0.8) ? pick(livePages()) : pick(allPages()),
          payload: p,
          sortIndex: rng.nextInt(6),
          expectedElementRevision: row is ReadableElementRow && chance(0.8)
              ? rev(row.revision)
              : null,
        );
      case 7:
      case 8:
        return elementPatch(opId);
      case 9:
        final id = pick(elementIds());
        final row = rows.element(id);
        return ElementDeleteOp(
          opId: opId,
          elementPublicId: id,
          pagePublicId: row?.pagePublicId ?? 'p0',
          expectedElementRevision: rev(
            row is ReadableElementRow ? row.revision : 1,
          ),
          lastWriterWins: chance(0.5),
        );
      case 10:
        final id = pick(elementIds());
        final row = rows.element(id);
        return ElementReorderOp(
          opId: opId,
          elementPublicId: id,
          pagePublicId: row?.pagePublicId ?? 'p0',
          sortIndex: rng.nextInt(6),
          expectedElementRevision: rev(
            row is ReadableElementRow ? row.revision : 1,
          ),
        );
      case 11:
        if (chance(0.5)) {
          final existing = chance(0.3);
          final id = existing ? pick(groupIds()) : 'g${newId()}';
          final row = rows.lineupGroup(id);
          final overlap = chance(0.15);
          final n = overlap ? pick(['0', '1']) : newId();
          final p = row != null && chance(0.5) ? row.payload : _group(id, n);
          return LineupGroupAddOp(
            opId: opId,
            lineupPublicId: id,
            pagePublicId: chance(0.8) ? pick(livePages()) : pick(allPages()),
            payload: p,
            sortIndex: rng.nextInt(3),
            expectedLineupRevision: row != null && chance(0.8)
                ? rev(row.revision)
                : null,
          );
        }
        final id = pick(groupIds());
        final row = rows.lineupGroup(id);
        return chance(0.5)
            ? LineupGroupDeleteOp(
                opId: opId,
                lineupPublicId: id,
                pagePublicId: row?.pagePublicId ?? 'p0',
                expectedLineupRevision: rev(row?.revision ?? 1),
                lastWriterWins: chance(0.5),
              )
            : LineupGroupReorderOp(
                opId: opId,
                lineupPublicId: id,
                pagePublicId: row?.pagePublicId ?? 'p0',
                sortIndex: rng.nextInt(4),
                expectedLineupRevision: rev(row?.revision ?? 1),
              );
      default:
        final id = pick(groupIds());
        final row = rows.lineupGroup(id);
        if (row == null) {
          return LineupGroupPatchOp(
            opId: opId,
            lineupPublicId: id,
            expectedLineupRevision: 1,
            payload: _group(id, '9'),
          );
        }
        final fields = <String>[];
        final edited = editedGroup(row, fields);
        final sortIndex = chance(0.2) ? rng.nextInt(4) : null;
        FieldMerge? merge;
        if (chance(0.65)) {
          if (sortIndex != null && chance(0.5)) fields.add('@sortIndex');
          Map<String, Object?>? base;
          if (chance(0.35)) {
            final older = pick(groupHistory[id] ?? [row.payload.data]);
            base = {};
            for (final f in fields) {
              if (f == '@sortIndex') {
                base[f] = row.sortIndex;
                continue;
              }
              final slash = f.indexOf('/');
              final items =
                  older[f.substring(0, slash)] as List<Object?>? ?? [];
              for (final item in items.cast<Map<String, Object?>>()) {
                if (item['id'] == f.substring(slash + 1)) base[f] = item;
              }
            }
          }
          merge = FieldMerge(fields: fields, base: base);
        }
        return LineupGroupPatchOp(
          opId: opId,
          lineupPublicId: id,
          expectedLineupRevision: rev(row.revision),
          payload: edited,
          sortIndex: sortIndex,
          pagePublicId: chance(0.1) ? pick(allPages()) : null,
          merge: merge,
        );
    }
  }

  final ops = <Map<String, Object?>>[];
  final predicted = <Map<String, Object?>>[];
  for (var step = 0; step < steps; step++) {
    final op = nextOp('s$seed-op$step');
    final result = applyOp(rows, op);
    if (result is OpApplied) {
      rows = rows.withRows(result.rows);
      for (final row in result.rows) {
        if (row case ReadableElementRow(:final payload)) {
          (history[row.publicId] ??= []).add(payload.data);
        }
        if (row case LineupGroupRow(:final payload)) {
          (groupHistory[row.publicId] ??= []).add(payload.data);
        }
      }
    }
    ops.add(op.toJson());
    predicted.add({...outcomeJson(result), 'rows': _rowsJson(rows)});
  }
  return {'seed': seed, 'initial': initial, 'ops': ops, 'predicted': predicted};
}
