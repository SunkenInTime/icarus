import 'package:icarus_library/icarus_library.dart';

const storyStrategyId = 'merge-stories';

final class MergeStory {
  MergeStory(
    this.name, {
    required this.ops,
    required this.outcomes,
    required this.expected,
  });

  final String name;
  final List<StrategyOp> ops;
  final List<Map<String, Object?>> outcomes;
  final Map<String, Map<String, Object?>> expected;
}

Map<String, Object?> outcomeJson(ApplyResult result) => switch (result) {
  OpApplied() => {'status': 'applied'},
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

const _applied = {'status': 'applied'};
const _noop = {'status': 'noop'};
Map<String, Object?> _rejected(String reason) => {
  'status': 'rejected',
  'reason': reason,
};

LiveElement _element(String id, ElementKind kind, Map<String, Object?> data) =>
    LiveElement(
      publicId: id,
      pagePublicId: 'p0',
      payload: ElementPayload(
        kind: kind,
        payloadVersion: 1,
        data: {'id': id, 'elementType': kind.name, ...data},
      ),
      sortIndex: 0,
      revision: 1,
    );

final _jett = _element('jett', ElementKind.agent, {
  'type': 'jett',
  'position': {'x': 1, 'y': 1},
  'isAlly': true,
  'state': 'none',
  'weapon': 'none',
});

final _note = _element('note', ElementKind.text, {
  'text': 'smoke heaven',
  'position': {'x': 2, 'y': 2},
  'size': 100,
  'fontSize': 12,
  'sizeVersion': 1,
});

final _box = _element('box', ElementKind.utility, {
  'type': 'customRectangle',
  'position': {'x': 3, 'y': 3},
  'rotation': 0,
  'customWidth': 40,
  'customLength': 20,
});

final _cone = _element('cone', ElementKind.utility, {
  'type': 'viewCone90',
  'position': {'x': 4, 'y': 4},
  'rotation': 0,
  'length': 30,
});

final _tide = _element('tide', ElementKind.ability, {
  'type': 'highTide',
  'position': {'x': 5, 'y': 5},
  'visualState': {'showRange': false},
});

final _line = _element('line', ElementKind.drawing, {
  'listOfPoints': [
    {'x': 0, 'y': 0},
    {'x': 10, 'y': 10},
  ],
  'boundingBox': {'left': 0, 'top': 0, 'right': 10, 'bottom': 10},
  'color': 1,
});

Map<String, Object?> _origin(String id) => {
  'id': id,
  'agent': {'type': 'sova', 'lineUpID': id},
};

Map<String, Object?> _landing(String id) => {
  'id': id,
  'ability': {'type': 'recon', 'lineUpID': id},
};

Map<String, Object?> _link(
  String id,
  String origin,
  String landing,
  String notes,
) => {'id': id, 'originId': origin, 'landingId': landing, 'notes': notes};

final _group = LiveLineupGroup(
  strategyPublicId: storyStrategyId,
  publicId: 'g0',
  pagePublicId: 'p0',
  payload: LineupGroupPayload(
    payloadVersion: 1,
    data: {
      'id': 'g0',
      'origins': [_origin('o0'), _origin('o1')],
      'landings': [_landing('l0'), _landing('l1')],
      'links': [_link('k0', 'o0', 'l0', ''), _link('k1', 'o1', 'l1', '')],
    },
  ),
  sortIndex: 0,
  revision: 1,
);

final storyRows = StrategyRowSet(
  strategy: const StrategyRow(
    publicId: storyStrategyId,
    name: 'Merges',
    mapData: 'ascent',
    revision: 1,
  ),
  pages: [
    for (final (index, id) in ['p0', 'p1'].indexed)
      LivePage(
        publicId: id,
        strategyPublicId: storyStrategyId,
        name: 'Page ${index + 1}',
        isAutoNamed: true,
        sortIndex: index,
        isAttack: true,
        revision: 1,
      ),
  ],
  settings: [
    for (final id in ['p0', 'p1'])
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
  elements: [_jett, _note, _box, _cone, _tide, _line],
  lineupGroups: [_group],
);

ElementPayload _with(LiveElement row, Map<String, Object?> changes) =>
    ElementPayload(
      kind: row.payload.kind,
      payloadVersion: row.payload.payloadVersion,
      data: {...row.payload.data, ...changes},
    );

ElementPatchOp _edit(
  String opId,
  LiveElement base,
  Map<String, Object?> changes, {
  Connection connection = Connection.live,
}) => elementEditOp(
  opId: opId,
  base: base,
  payload: _with(base, changes),
  sortIndex: base.sortIndex,
  connection: connection,
);

LiveElement _after(LiveElement row, StrategyOp op) => switch (applyOp(
  StrategyRowSet(
    strategy: storyRows.strategy,
    pages: storyRows.pages,
    settings: storyRows.settings,
    elements: [row],
    lineupGroups: const [],
  ),
  op,
)) {
  OpApplied(:final rows) => rows.whereType<LiveElement>().single,
  final other => throw StateError('$op did not apply: $other'),
};

StrategyOp _undo(LiveElement row, StrategyOp op) => switch (applyOp(
  StrategyRowSet(
    strategy: storyRows.strategy,
    pages: storyRows.pages,
    settings: storyRows.settings,
    elements: [row],
    lineupGroups: const [],
  ),
  op,
)) {
  OpApplied(undo: UndoWithOp(:final op)) => op,
  final other => throw StateError('$op has no undo op: $other'),
};

LineupGroupPayload _groupWith({
  List<String> withoutLinks = const [],
  List<Map<String, Object?>> addLinks = const [],
  List<Map<String, Object?>> addLandings = const [],
  Map<String, String> notes = const {},
}) {
  final data = _group.payload.data;
  final links = [
    for (final link in data['links']! as List<Object?>)
      if (link case final Map<String, Object?> link
          when !withoutLinks.contains(link['id']))
        {...link, 'notes': ?notes[link['id']]},
    ...addLinks,
  ];
  final usedOrigins = {for (final link in links) link['originId']};
  final usedLandings = {for (final link in links) link['landingId']};
  return LineupGroupPayload(
    payloadVersion: 1,
    data: {
      'id': 'g0',
      'origins': [
        for (final origin in data['origins']! as List<Object?>)
          if (origin case final Map<String, Object?> origin
              when usedOrigins.contains(origin['id']))
            origin,
      ],
      'landings': [
        for (final landing in [
          ...data['landings']! as List<Object?>,
          ...addLandings,
        ])
          if (landing case final Map<String, Object?> landing
              when usedLandings.contains(landing['id']))
            landing,
      ],
      'links': links,
    },
  );
}

LineupGroupPatchOp _groupEdit(String opId, LineupGroupPayload payload) =>
    lineupEditOp(
      opId: opId,
      base: _group,
      payload: payload,
      sortIndex: _group.sortIndex,
      connection: Connection.live,
    );

List<MergeStory> mergeStories() {
  final captioned = _edit('caption-add', _jett, {
    'caption': 'entry',
    'position': {'x': 7, 'y': 7},
  });
  final walled = _edit('wall-add', _tide, {
    'wallPath': [
      {'x': 3, 'y': 0},
    ],
  });
  final firstCaption = _edit('caption-first', _jett, {'caption': 'entry'});
  return [
    MergeStory(
      'two people move and recolour one agent online, both keep their change',
      ops: [
        _edit('move', _jett, {
          'position': {'x': 5, 'y': 5},
        }),
        _edit('recolour', _jett, {'isAlly': false}),
      ],
      outcomes: [_applied, _applied],
      expected: {
        'jett': {
          'position': {'x': 5, 'y': 5},
          'isAlly': false,
        },
      },
    ),
    MergeStory(
      'two people move one agent online, the later move wins',
      ops: [
        _edit('move-1', _jett, {
          'position': {'x': 5, 'y': 5},
        }),
        _edit('move-2', _jett, {
          'position': {'x': 9, 'y': 9},
        }),
      ],
      outcomes: [_applied, _applied],
      expected: {
        'jett': {
          'position': {'x': 9, 'y': 9},
        },
      },
    ),
    MergeStory(
      'a move made offline that collides with a teammate\'s move waits for '
      'the user',
      ops: [
        _edit('move-online', _jett, {
          'position': {'x': 5, 'y': 5},
        }),
        _edit('move-offline', _jett, {
          'position': {'x': 9, 'y': 9},
        }, connection: Connection.offline),
      ],
      outcomes: [_applied, _rejected('field_conflict')],
      expected: {
        'jett': {
          'position': {'x': 5, 'y': 5},
        },
      },
    ),
    MergeStory(
      'a recolour made offline lands beside a teammate\'s move',
      ops: [
        _edit('move-online', _jett, {
          'position': {'x': 5, 'y': 5},
        }),
        _edit('recolour-offline', _jett, {
          'isAlly': false,
        }, connection: Connection.offline),
      ],
      outcomes: [_applied, _applied],
      expected: {
        'jett': {
          'position': {'x': 5, 'y': 5},
          'isAlly': false,
        },
      },
    ),
    MergeStory(
      'an offline move to where a teammate already put it is no collision',
      ops: [
        _edit('move-online', _jett, {
          'position': {'x': 5, 'y': 5},
        }),
        _edit('move-offline', _jett, {
          'position': {'x': 5, 'y': 5},
        }, connection: Connection.offline),
      ],
      outcomes: [_applied, _noop],
      expected: {
        'jett': {
          'position': {'x': 5, 'y': 5},
        },
      },
    ),
    MergeStory(
      'resizing text keeps its box whole over a teammate\'s move',
      ops: [
        _edit('move', _note, {
          'position': {'x': 8, 'y': 8},
        }),
        _edit('resize', _note, {'fontSize': 20}),
      ],
      outcomes: [_applied, _applied],
      expected: {
        'note': {
          'position': {'x': 2, 'y': 2},
          'fontSize': 20,
        },
      },
    ),
    MergeStory(
      'a drawing\'s points and bounding box move together',
      ops: [
        _edit('reshape', _line, {
          'listOfPoints': [
            {'x': 0, 'y': 0},
            {'x': 20, 'y': 20},
          ],
          'boundingBox': {'left': 0, 'top': 0, 'right': 20, 'bottom': 20},
        }),
        _edit('reorder-points', _line, {
          'listOfPoints': [
            {'x': 10, 'y': 10},
            {'x': 0, 'y': 0},
          ],
        }),
      ],
      outcomes: [_applied, _applied],
      expected: {
        'line': {
          'listOfPoints': [
            {'x': 10, 'y': 10},
            {'x': 0, 'y': 0},
          ],
          'boundingBox': {'left': 0, 'top': 0, 'right': 10, 'bottom': 10},
        },
      },
    ),
    MergeStory(
      'resizing a custom rectangle moves it with its size',
      ops: [
        _edit('move', _box, {
          'position': {'x': 9, 'y': 9},
        }),
        _edit('resize', _box, {'customWidth': 60}),
      ],
      outcomes: [_applied, _applied],
      expected: {
        'box': {
          'position': {'x': 3, 'y': 3},
          'customWidth': 60,
        },
      },
    ),
    MergeStory(
      'turning a view cone leaves a teammate\'s move of it alone',
      ops: [
        _edit('move', _cone, {
          'position': {'x': 9, 'y': 9},
        }),
        _edit('turn', _cone, {'rotation': 90}),
      ],
      outcomes: [_applied, _applied],
      expected: {
        'cone': {
          'position': {'x': 9, 'y': 9},
          'rotation': 90,
          'length': 30,
        },
      },
    ),
    MergeStory(
      'a vision cone shown by default is not written over a teammate\'s '
      'change to the ability',
      ops: [
        _edit('show-range', _tide, {
          'visualState': {'showRange': true},
        }),
        _edit('move', _tide, {
          'position': {'x': 6, 'y': 6},
          'visualState': {'showRange': false, 'showVisionCone': true},
        }),
      ],
      outcomes: [_applied, _applied],
      expected: {
        'tide': {
          'position': {'x': 6, 'y': 6},
          'visualState': {'showRange': true},
        },
      },
    ),
    MergeStory(
      'undo of a caption added together with a move restores both',
      ops: [captioned, _undo(_jett, captioned)],
      outcomes: [_applied, _applied],
      expected: {
        'jett': {
          'caption': '',
          'position': {'x': 1, 'y': 1},
        },
      },
    ),
    MergeStory(
      'undo of a first wall path removes the wall',
      ops: [walled, _undo(_tide, walled)],
      outcomes: [_applied, _applied],
      expected: {
        'tide': {'wallPath': <Object?>[]},
      },
    ),
    MergeStory(
      'a build that predates captions keeps the caption when it moves the item',
      ops: [
        firstCaption,
        ElementPatchOp(
          opId: 'old-build-move',
          elementPublicId: 'jett',
          expectedElementRevision: 2,
          payload: _with(_jett, {
            'position': {'x': 3, 'y': 3},
          }),
        ),
      ],
      outcomes: [_applied, _applied],
      expected: {
        'jett': {
          'caption': 'entry',
          'position': {'x': 3, 'y': 3},
        },
      },
    ),
    MergeStory(
      'a caption is cleared by writing its empty value',
      ops: [
        firstCaption,
        _edit('caption-clear', _after(_jett, firstCaption), {'caption': ''}),
      ],
      outcomes: [_applied, _applied],
      expected: {
        'jett': {'caption': ''},
      },
    ),
    MergeStory(
      'changing which agent it is writes the whole item and is refused over a '
      'teammate\'s move',
      ops: [
        _edit('move', _jett, {
          'position': {'x': 5, 'y': 5},
        }),
        _edit('swap-agent', _jett, {'type': 'sova'}),
      ],
      outcomes: [_applied, _rejected('revision_mismatch')],
      expected: {
        'jett': {
          'type': 'jett',
          'position': {'x': 5, 'y': 5},
        },
      },
    ),
    MergeStory(
      'an edit drawn on another payload version writes the whole item',
      ops: [
        _edit('move', _jett, {
          'position': {'x': 5, 'y': 5},
        }),
        ElementPatchOp(
          opId: 'newer-version',
          elementPublicId: 'jett',
          expectedElementRevision: 1,
          payload: ElementPayload(
            kind: ElementKind.agent,
            payloadVersion: 2,
            data: {..._jett.payload.data, 'isAlly': false},
          ),
          merge: FieldMerge(fields: ['isAlly']),
        ),
      ],
      outcomes: [_applied, _rejected('revision_mismatch')],
      expected: {
        'jett': {
          'position': {'x': 5, 'y': 5},
          'isAlly': true,
        },
      },
    ),
    MergeStory(
      'two people add to one lineup group online and both lineups stay',
      ops: [
        _groupEdit('note', _groupWith(notes: {'k0': 'jump throw'})),
        _groupEdit(
          'add',
          _groupWith(
            addLandings: [_landing('l2')],
            addLinks: [_link('k2', 'o0', 'l2', '')],
          ),
        ),
      ],
      outcomes: [_applied, _applied],
      expected: {
        'g0': {
          'links': [
            _link('k0', 'o0', 'l0', 'jump throw'),
            _link('k1', 'o1', 'l1', ''),
            _link('k2', 'o0', 'l2', ''),
          ],
        },
      },
    ),
    MergeStory(
      'a lineup added on a spot a teammate removed is refused as invalid',
      ops: [
        _groupEdit('remove', _groupWith(withoutLinks: ['k0'])),
        _groupEdit(
          'add',
          _groupWith(
            addLandings: [_landing('l2')],
            addLinks: [_link('k2', 'o0', 'l2', '')],
          ),
        ),
      ],
      outcomes: [_applied, _rejected('merge_invalid')],
      expected: {
        'g0': {
          'origins': [_origin('o1')],
          'links': [_link('k1', 'o1', 'l1', '')],
        },
      },
    ),
  ];
}
