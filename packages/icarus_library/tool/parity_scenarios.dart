import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:icarus_library/icarus_library.dart';

import 'merge_seeds.dart';
import 'merge_stories.dart';

const _strategyId = 's1';
const _largestSafeInteger = 9007199254740991;
const _maxArrayEntries = 8000;

void main(List<String> args) {
  switch (args) {
    case [
      'generate',
      final samples,
      final first,
      final seeds,
      final steps,
      final out,
    ]:
      final corpus = _Samples.read(samples);
      final from = int.parse(first);
      final count = int.parse(seeds);
      final length = int.parse(steps);
      _write(out, [
        for (var seed = from; seed < from + count; seed++)
          _Generator(seed, corpus).scenario(length),
      ]);
    case ['stories', final out]:
      Map<String, Object?> rowsJson(StrategyRowSet rows) =>
          _rowsJson(rows, const []);
      _write(out, [
        for (final story in mergeStories()) _story(story),
        ...mergeSeedScenarios(rowsJson, _outcome),
      ]);
    case ['replay', final input, final out]:
      final recorded = jsonDecode(File(input).readAsStringSync());
      if (recorded is! Map<String, Object?>) {
        stderr.writeln('$input is not a recorded sequence');
        exitCode = 65;
        return;
      }
      _write(out, [_replay(recorded)]);
    default:
      stderr.writeln(
        'usage: parity_scenarios generate <samples> <first seed> <seeds> '
        '<steps> <out>\n'
        '       parity_scenarios replay <recorded sequence> <out>\n'
        '       parity_scenarios stories <out>',
      );
      exitCode = 64;
  }
}

void _write(String out, List<Map<String, Object?>> scenarios) {
  for (final scenario in scenarios) {
    _assertSafeNumbers(
      scenario,
      '${scenario['name'] ?? 'seed ${scenario['seed']}'}',
    );
  }
  File(out).writeAsStringSync(jsonEncode(scenarios));
}

void _assertSafeNumbers(Object? value, String path) {
  switch (value) {
    case num() when !value.isFinite || value.abs() > _largestSafeInteger:
      throw StateError('$path holds $value, which JavaScript cannot hold');
    case List<Object?>():
      for (final (index, item) in value.indexed) {
        _assertSafeNumbers(item, '$path[$index]');
      }
    case Map<Object?, Object?>():
      for (final MapEntry(:key, :value) in value.entries) {
        _assertSafeNumbers(value, '$path.$key');
      }
    default:
      break;
  }
}

ReadablePageRow? _page(StrategyRows rows, String id) => switch (rows.page(id)) {
  final ReadablePageRow page => page,
  _ => null,
};

ReadablePageSettings? _settingsOf(StrategyRows rows, String id) =>
    switch (rows.settingsOf(id)) {
      final ReadablePageSettings settings => settings,
      _ => null,
    };

ReadableLineupGroupRow? _group(StrategyRows rows, String id) =>
    switch (rows.lineupGroup(id)) {
      final ReadableLineupGroupRow group => group,
      _ => null,
    };

Iterable<ReadableLineupGroupRow> _groups(StrategyRowSet rows) =>
    rows.lineupGroups.whereType<ReadableLineupGroupRow>();

Map<String, Object?> _rowsJson(StrategyRowSet rows, List<FolderRow> folders) =>
    {
      'strategy': {
        for (final MapEntry(:key, :value) in rows.strategy.toJson().entries)
          if (key != 'createdAt' && key != 'updatedAt') key: value,
      },
      'folders': [for (final row in folders) row.toJson()],
      'pages': [for (final row in rows.pages) row.toJson()],
      'settings': [for (final row in rows.settings) row.toJson()],
      'elements': [for (final row in rows.elements) row.toJson()],
      'lineupGroups': [for (final row in rows.lineupGroups) row.toJson()],
    };

int? _revisionOf(StrategyRows rows, StrategyOp op) => switch (op) {
  StrategyPatchOp() ||
  PageAddOp() ||
  PageDeleteOp() ||
  PageReorderOp() => rows.strategy.revision,
  PagePatchOp(:final pagePublicId) => _page(rows, pagePublicId)?.revision,
  PageSettingsPatchOp(:final pagePublicId) => _settingsOf(
    rows,
    pagePublicId,
  )?.revision,
  ElementAddOp(:final elementPublicId) ||
  ElementPatchOp(:final elementPublicId) ||
  ElementDeleteOp(:final elementPublicId) ||
  ElementReorderOp(:final elementPublicId) => switch (rows.element(
    elementPublicId,
  )) {
    ReadableElementRow(:final revision) => revision,
    _ => null,
  },
  LineupGroupAddOp(:final lineupPublicId) ||
  LineupGroupPatchOp(:final lineupPublicId) ||
  LineupGroupDeleteOp(:final lineupPublicId) ||
  LineupGroupReorderOp(
    :final lineupPublicId,
  ) => _group(rows, lineupPublicId)?.revision,
};

Map<String, Object?> _outcome(
  ApplyResult result,
  StrategyOp op,
  StrategyRows after,
) => switch (result) {
  OpApplied(:final writes)
      when writes.map((write) => write.key).toSet().length != writes.length =>
    {'status': 'applyOp wrote one row twice'},
  OpApplied() => {
    'status': 'applied',
    'appliedRevision': _revisionOf(after, op),
  },
  OpUnchanged() => {'status': 'noop'},
  OpRefused(refusal: Rejected(:final reason)) => {
    'status': 'rejected',
    'reason': reason.wireName,
  },
  OpRefused(refusal: Failed(:final code)) => {
    'status': 'failed',
    'code': code.wireName,
  },
  OpRefused(refusal: UnreadableTarget()) => {'status': 'unreadable'},
};

T _read<T>(Decoded<T> decoded) => switch (decoded) {
  Read(:final value) => value,
  CouldNotRead(:final problem) => throw StateError(problem),
};

List<Object?> _list(Object? value) => value is List<Object?> ? value : const [];

Map<String, Object?> _replay(Map<String, Object?> recorded) {
  final initial = recorded['initial']! as Map<String, Object?>;
  bool canRead(ElementPayload payload) => true;
  final folders = [
    for (final row in _list(initial['folders'])) _read(FolderRow.decode(row)),
  ];
  var rows = StrategyRowSet(
    strategy: _read(
      StrategyRow.decode({
        'createdAt': 0,
        'updatedAt': 0,
        ...initial['strategy']! as Map<String, Object?>,
      }),
    ),
    pages: [
      for (final row in _list(initial['pages'])) _read(PageRow.decode(row)),
    ],
    settings: [
      for (final row in _list(initial['settings']))
        _read(PageSettingsRow.decode(row)),
    ],
    elements: [
      for (final row in _list(initial['elements']))
        _read(ElementRow.decode(row, canRead: canRead)),
    ],
    lineupGroups: [
      for (final row in _list(initial['lineupGroups']))
        _read(LineupGroupRow.decode(row, canRead: (_) => true)),
    ],
  );
  final raw = _list(recorded['ops']);
  if (recorded['steps'] != raw.length) {
    throw StateError(
      'the file says ${recorded['steps']} steps but holds ${raw.length} ops',
    );
  }
  final predicted = <Map<String, Object?>>[];
  for (final (step, json) in raw.indexed) {
    final op = switch (StrategyOp.decode(json)) {
      Read(:final value) => value,
      CouldNotRead(:final problem) => throw StateError(
        'op $step cannot be read: $problem',
      ),
    };
    if (jsonEncode(op.toJson()) != jsonEncode(json)) {
      throw StateError('op $step does not read back as it was recorded');
    }
    final result = applyOp(rows, op);
    if (result is OpApplied) rows = rows.withRows(result.rows);
    predicted.add({
      ..._outcome(result, op, rows),
      'rows': _rowsJson(rows, folders),
    });
  }
  return {
    'seed': recorded['seed'],
    'steps': raw.length,
    'dartVersion': Platform.version,
    'initial': initial,
    'ops': raw,
    'predicted': predicted,
  };
}

final class _Samples {
  _Samples(this.elements, this.lineupGroups);

  factory _Samples.read(String path) {
    final json =
        jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
    return _Samples(
      [
        for (final sample in _list(json['elements']))
          _read(ElementPayload.decode(sample)),
      ],
      [
        for (final sample in _list(json['lineupGroups']))
          _read(LineupGroupPayload.decode(sample)),
      ],
    );
  }

  final List<ElementPayload> elements;
  final List<LineupGroupPayload> lineupGroups;

  List<ElementPayload> ofKind(ElementKind kind) => [
    for (final sample in elements)
      if (sample.kind == kind) sample,
  ];
}

const _identityKeys = {'id', 'elementType', 'kind', 'type', 'data'};

const _settingsChoices = [
  PageSettings(agentSize: 1, abilitySize: 1, useNeutralTeamColors: false),
  PageSettings(agentSize: 1.5, abilitySize: 0.75, useNeutralTeamColors: true),
];

final class _Generator {
  _Generator(this.seed, this.samples) : rng = Random(seed);

  final int seed;
  final _Samples samples;
  final Random rng;
  int _fresh = 0;
  late StrategyRowSet rows;
  late List<FolderRow> folders;
  final history = <String, List<Map<String, Object?>>>{};
  final groupHistory = <String, List<Map<String, Object?>>>{};

  String newId() => 's$seed-n${_fresh++}';

  T pick<T>(List<T> list) => list[rng.nextInt(list.length)];

  bool chance(double p) => rng.nextDouble() < p;

  int rev(int current) => chance(0.85) ? current : current + pick([-1, 1]);

  Map<String, Object?> scenario(int steps) {
    folders = [
      ReadableFolder(publicId: 'f-root', name: 'Retakes', color: 'red'),
      ReadableFolder(
        publicId: 'f-child',
        name: 'Bind',
        parentFolderPublicId: 'f-root',
        iconCodePoint: 58000,
      ),
    ];
    final pageIds = ['p0', 'p1', 'p2'];
    rows = StrategyRowSet(
      strategy: ReadableStrategy(
        publicId: _strategyId,
        name: 'Retake',
        mapData: 'ascent',
        revision: 1,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        folderPublicId: switch (seed % 3) {
          0 => null,
          1 => 'f-root',
          _ => 'f-child',
        },
      ),
      pages: [
        for (final (i, id) in pageIds.indexed)
          LivePage(
            publicId: id,
            strategyPublicId: _strategyId,
            name: i < 2 ? 'Page ${i + 1}' : 'Exec',
            isAutoNamed: i < 2,
            sortIndex: i,
            isAttack: true,
            revision: 1,
          ),
      ],
      settings: [
        for (final id in pageIds)
          ReadablePageSettings(
            pagePublicId: id,
            settings: _settingsChoices.first,
            revision: 1,
          ),
      ],
      elements: [
        for (final (i, kind) in ElementKind.values.indexed)
          LiveElement(
            publicId: 's$seed-e$i',
            pagePublicId: pageIds[i % 2],
            payload: elementPayload('s$seed-e$i', kind),
            sortIndex: i,
            revision: 1,
          ),
      ],
      lineupGroups: [
        for (final (i, page) in ['p0', 'p1'].indexed)
          LiveLineupGroup(
            strategyPublicId: _strategyId,
            publicId: 's$seed-g$i',
            pagePublicId: page,
            payload: groupPayload('s$seed-g$i'),
            sortIndex: 0,
            revision: 1,
          ),
      ],
    );
    final initial = _rowsJson(rows, folders);
    for (final element in rows.elements) {
      remember(element);
    }
    for (final group in _groups(rows)) {
      groupHistory[group.publicId] = [group.payload.data];
    }
    final ops = <Map<String, Object?>>[];
    final predicted = <Map<String, Object?>>[];
    for (var step = 0; step < steps; step++) {
      final op = nextOp('s$seed-op$step');
      final result = applyOp(rows, op);
      if (result is OpApplied) {
        rows = rows.withRows(result.rows);
        for (final row in result.rows) {
          switch (row) {
            case final ElementRow element:
              remember(element);
            case ReadableLineupGroupRow(:final publicId, :final payload):
              (groupHistory[publicId] ??= []).add(payload.data);
            default:
              break;
          }
        }
      }
      ops.add(op.toJson());
      predicted.add({
        ..._outcome(result, op, rows),
        'rows': _rowsJson(rows, folders),
      });
    }
    return {
      'seed': seed,
      'steps': steps,
      'dartVersion': Platform.version,
      'initial': initial,
      'ops': ops,
      'predicted': predicted,
    };
  }

  void remember(ElementRow row) {
    if (row case ReadableElementRow(:final payload)) {
      (history[row.publicId] ??= []).add(payload.data);
    }
  }

  ElementPayload elementPayload(String id, ElementKind kind) {
    final sample = pick(samples.ofKind(kind));
    return ElementPayload(
      kind: sample.kind,
      payloadVersion: sample.payloadVersion,
      data: {
        ...sample.data,
        'id': id,
        if (sample.data.containsKey('assetId'))
          'assetId': chance(0.3) ? 'picture-shared' : 'picture-$id',
      },
    );
  }

  ElementPayload longDrawing(String id, int points) {
    final freehand = [
      for (final sample in samples.ofKind(ElementKind.drawing))
        if (sample.data['listOfPoints'] is List<Object?>) sample,
    ].first;
    return ElementPayload(
      kind: ElementKind.drawing,
      payloadVersion: freehand.payloadVersion,
      data: {
        ...freehand.data,
        'id': id,
        'listOfPoints': [
          for (var i = 0; i < points; i++) {'dx': i % 1000, 'dy': i ~/ 1000},
        ],
      },
    );
  }

  LineupGroupPayload groupPayload(String id) {
    final sample = pick(samples.lineupGroups);
    final renamed = <String, String>{};
    void collect(Object? value) {
      switch (value) {
        case {'id': final String itemId}:
          renamed[itemId] = '$id/$itemId';
          for (final nested in (value as Map<String, Object?>).values) {
            collect(nested);
          }
        case List<Object?>():
          value.forEach(collect);
        default:
          break;
      }
    }

    for (final key in ['origins', 'landings', 'links']) {
      collect(sample.data[key]);
    }
    Object? rename(Object? value) => switch (value) {
      final String text => renamed[text] ?? text,
      final List<Object?> list => [for (final item in list) rename(item)],
      final Map<String, Object?> map => {
        for (final MapEntry(:key, :value) in map.entries) key: rename(value),
      },
      _ => value,
    };
    return LineupGroupPayload(
      payloadVersion: sample.payloadVersion,
      data: {
        ...sample.data,
        'id': id,
        for (final key in ['origins', 'landings', 'links'])
          key: rename(sample.data[key]),
      },
    );
  }

  List<String> allPages() => [
    ...rows.pages.map((p) => p.publicId),
    'p-missing',
  ];

  List<String> trashedPages() => [
    for (final p in rows.pages)
      if (p is TrashedPage) p.publicId,
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

  Object? nudged(Object? value) => switch (value) {
    final bool flag => !flag,
    final int number => number + 1 + rng.nextInt(5),
    final double number => number + 0.5 + rng.nextInt(5),
    final String text => '$text~${rng.nextInt(3)}',
    {'dx': final num dx, 'dy': final num dy} => {
      ...(value as Map<String, Object?>),
      'dx': dx + 10 + rng.nextInt(50),
      'dy': dy + 10 + rng.nextInt(50),
    },
    final Map<String, Object?> map when map.isNotEmpty => () {
      final key = pick(map.keys.toList());
      return {...map, key: nudged(map[key])};
    }(),
    final List<Object?> list when list.isNotEmpty => [
      ...list.skip(1),
      nudged(list.first),
    ],
    _ => chance(0.5) ? 'set' : value,
  };

  StrategyOp elementPatch(String opId) {
    final id = pick(elementIds());
    final row = rows.element(id);
    final current = switch (row) {
      ReadableElementRow(:final payload) => payload,
      _ => elementPayload(id, pick(ElementKind.values)),
    };
    final data = {...current.data};
    final editable = [
      for (final key in data.keys)
        if (!_identityKeys.contains(key)) key,
    ];
    final changed = <String>{};
    for (var n = rng.nextInt(3) + 1; n > 0 && editable.isNotEmpty; n--) {
      final key = pick(editable);
      data[key] = nudged(data[key]);
      changed.add(key);
    }
    if (current.kind != ElementKind.drawing && chance(0.2)) {
      if (chance(0.5)) {
        data.remove('caption');
      } else {
        data['caption'] = 'c${rng.nextInt(3)}';
      }
      changed.add('caption');
    }
    if (chance(0.04)) {
      data['type'] = 'flipped';
      changed.add('type');
    }
    var kind = current.kind;
    if (chance(0.03)) {
      kind = pick([
        for (final other in ElementKind.values)
          if (other != kind) other,
      ]);
      data['elementType'] = kind.name;
    }
    final payloadVersion = chance(0.04) && current.payloadVersion < 3
        ? current.payloadVersion + 1
        : current.payloadVersion;
    final sent = ElementPayload(
      kind: kind,
      payloadVersion: payloadVersion,
      data: data,
    );
    final sortIndex = chance(0.3) ? rng.nextInt(8) : null;
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
              f: chance(0.7) && row is ReadableElementRow
                  ? row.sortIndex
                  : rng.nextInt(8)
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
      payload: chance(0.9) ? sent : null,
      sortIndex: sortIndex,
      pagePublicId: chance(0.15) ? pick(allPages()) : null,
      merge: merge,
    );
  }

  List<Map<String, Object?>> items(Map<String, Object?> data, String key) => [
    for (final item in _list(data[key]))
      if (item is Map<String, Object?>) item,
  ];

  Map<String, Object?> fresh(Map<String, Object?> item, String id) {
    final marker = item['agent'] ?? item['ability'];
    return {
      ...item,
      'id': id,
      if (item['agent'] is Map<String, Object?>)
        'agent': {
          ...marker! as Map<String, Object?>,
          'lineUpID': id,
          'id': '$id-a',
        },
      if (item['ability'] is Map<String, Object?>)
        'ability': {
          ...marker! as Map<String, Object?>,
          'lineUpID': id,
          'id': '$id-a',
        },
    };
  }

  LineupGroupPayload editedGroup(
    ReadableLineupGroupRow row,
    List<String> fields,
  ) {
    final data = row.payload.data;
    final origins = items(data, 'origins');
    final landings = items(data, 'landings');
    final links = items(data, 'links');
    final roll = rng.nextInt(3);
    if (roll == 0 || links.isEmpty) {
      final n = newId();
      final useOrigin = chance(0.25) && origins.isNotEmpty;
      final originId = useOrigin ? pick(origins)['id']! as String : 'o$n';
      if (!useOrigin) {
        origins.add(
          fresh(
            origins.isEmpty ? {'agent': <String, Object?>{}} : origins.first,
            originId,
          ),
        );
        fields.add('origins/$originId');
      }
      landings.add(
        fresh(
          landings.isEmpty ? {'ability': <String, Object?>{}} : landings.first,
          'l$n',
        ),
      );
      fields.add('landings/l$n');
      links.add({
        ...(links.isEmpty ? <String, Object?>{} : links.first),
        'id': 'k$n',
        'originId': originId,
        'landingId': 'l$n',
      });
      fields.add('links/k$n');
    } else if (roll == 1) {
      final i = rng.nextInt(links.length);
      links[i] = {...links[i], 'notes': 'n${rng.nextInt(4)}'};
      fields.add('links/${links[i]['id']}');
    } else {
      final alone = [
        for (final (index, link) in links.indexed)
          if (links
                  .where((other) => other['originId'] == link['originId'])
                  .length ==
              1)
            index,
      ];
      final gone = links.removeAt(
        alone.isNotEmpty && chance(0.8)
            ? pick(alone)
            : rng.nextInt(links.length),
      );
      fields.add('links/${gone['id']}');
      final usedOrigins = {for (final link in links) link['originId']};
      final usedLandings = {for (final link in links) link['landingId']};
      for (final origin in [...origins]) {
        if (!usedOrigins.contains(origin['id'])) {
          origins.remove(origin);
          fields.add('origins/${origin['id']}');
        }
      }
      for (final landing in [...landings]) {
        if (!usedLandings.contains(landing['id'])) {
          landings.remove(landing);
          fields.add('landings/${landing['id']}');
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
    final row = _group(rows, id);
    if (row == null) return elementPatch(opId);
    final versions = groupHistory[id] ?? [row.payload.data];
    final current = {
      for (final origin in items(row.payload.data, 'origins')) origin['id'],
    };
    final lost = [
      for (final version in versions)
        for (final origin in items(version, 'origins'))
          if (!current.contains(origin['id']))
            (version, origin['id']! as String),
    ];
    final (older, lostOrigin) = lost.isNotEmpty && chance(0.8)
        ? pick(lost)
        : (pick(versions), null);
    final origins = items(older, 'origins');
    final landings = items(older, 'landings');
    final links = items(older, 'links');
    if (origins.isEmpty || landings.isEmpty || links.isEmpty) {
      return elementPatch(opId);
    }
    final n = newId();
    final originId = lostOrigin ?? pick(origins)['id']! as String;
    return LineupGroupPatchOp(
      opId: opId,
      lineupPublicId: id,
      expectedLineupRevision: row.revision,
      payload: LineupGroupPayload(
        payloadVersion: 1,
        data: {
          ...older,
          'landings': [...landings, fresh(landings.first, 'l$n')],
          'links': [
            ...links,
            {
              ...links.first,
              'id': 'k$n',
              'originId': originId,
              'landingId': 'l$n',
            },
          ],
        },
      ),
      merge: FieldMerge(fields: ['landings/l$n', 'links/k$n']),
    );
  }

  StrategyOp nextOp(String opId) {
    switch (rng.nextInt(16)) {
      case 0:
        return StrategyPatchOp(
          opId: opId,
          expectedStrategyRevision: rev(rows.strategy.revision),
          name: chance(0.5) ? 'S${rng.nextInt(3)}' : null,
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
        return PageAddOp(
          opId: opId,
          pagePublicId: trashedPages().isNotEmpty && chance(0.15)
              ? pick(trashedPages())
              : chance(0.2)
              ? pick(allPages())
              : 'p${newId()}',
          sortIndex: rng.nextInt(livePages().length + 2),
          expectedStrategyRevision: rev(rows.strategy.revision),
          name: chance(0.7) ? 'Page ${rng.nextInt(5) + 1}' : null,
          isAutoNamed: chance(0.7) ? chance(0.6) : null,
          isAttack: chance(0.5) ? chance(0.5) : null,
          settings: chance(0.8) ? pick(_settingsChoices) : null,
        );
      case 2:
        final id = pick(allPages());
        return PagePatchOp(
          opId: opId,
          pagePublicId: id,
          expectedPageRevision: rev(_page(rows, id)?.revision ?? 1),
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
          settings: pick(_settingsChoices),
          expectedPageSettingsRevision: rev(
            _settingsOf(rows, id)?.revision ?? 1,
          ),
        );
      case 6:
        final id = chance(0.4) ? pick(elementIds()) : 's$seed-${newId()}';
        final row = rows.element(id);
        final payload = chance(0.07)
            ? longDrawing(id, _maxArrayEntries + pick([0, 1]))
            : row is ReadableElementRow && chance(0.5)
            ? row.payload
            : elementPayload(id, pick(ElementKind.values));
        return ElementAddOp(
          opId: opId,
          elementPublicId: id,
          pagePublicId: chance(0.8) ? pick(livePages()) : pick(allPages()),
          payload: payload,
          sortIndex: rng.nextInt(8),
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
          sortIndex: rng.nextInt(8),
          expectedElementRevision: rev(
            row is ReadableElementRow ? row.revision : 1,
          ),
        );
      case 11:
        if (chance(0.5)) {
          final id = chance(0.3) ? pick(groupIds()) : 's$seed-g${newId()}';
          final row = _group(rows, id);
          final overlap = chance(0.15) && _groups(rows).isNotEmpty;
          final payload = row != null && chance(0.5)
              ? row.payload
              : overlap
              ? LineupGroupPayload(
                  payloadVersion: 1,
                  data: {
                    ...pick(_groups(rows).toList()).payload.data,
                    'id': id,
                  },
                )
              : groupPayload(id);
          return LineupGroupAddOp(
            opId: opId,
            lineupPublicId: id,
            pagePublicId: chance(0.8) ? pick(livePages()) : pick(allPages()),
            payload: payload,
            sortIndex: rng.nextInt(3),
            expectedLineupRevision: row != null && chance(0.8)
                ? rev(row.revision)
                : null,
          );
        }
        final id = pick(groupIds());
        final row = _group(rows, id);
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
      case 12:
      case 13:
        final id = pick(groupIds());
        final row = _group(rows, id);
        if (row == null) {
          return LineupGroupPatchOp(
            opId: opId,
            lineupPublicId: id,
            expectedLineupRevision: 1,
            payload: groupPayload(id),
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
            for (final field in fields) {
              if (field == '@sortIndex') {
                base[field] = row.sortIndex;
                continue;
              }
              final slash = field.indexOf('/');
              for (final item in items(older, field.substring(0, slash))) {
                if (item['id'] == field.substring(slash + 1)) {
                  base[field] = item;
                }
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
      default:
        return staleLineupMerge(opId);
    }
  }
}

Map<String, Object?> _story(MergeStory story) {
  var rows = storyRows;
  final predicted = <Map<String, Object?>>[];
  for (final op in story.ops) {
    final result = applyOp(rows, op);
    if (result is OpApplied) rows = rows.withRows(result.rows);
    predicted.add({
      ..._outcome(result, op, rows),
      'rows': _rowsJson(rows, const []),
    });
  }
  return {
    'name': story.name,
    'initial': _rowsJson(storyRows, const []),
    'ops': [for (final op in story.ops) op.toJson()],
    'predicted': predicted,
    'outcomes': story.outcomes,
    'expected': story.expected,
  };
}
