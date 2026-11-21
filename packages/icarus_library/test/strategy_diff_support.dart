import 'dart:math';

import 'package:icarus_library/icarus_library.dart';

import 'support.dart';

Map<String, Object?> origin(String id) => {
  'id': id,
  'agent': {'type': 'sova', 'lineUpID': id},
};

Map<String, Object?> landing(String id) => {
  'id': id,
  'ability': {'type': 'recon', 'lineUpID': id},
};

LiveLineupGroup lineupGroup(
  String id, {
  required String pageId,
  int sortIndex = 0,
  int revision = 1,
  String notes = '',
  int links = 1,
}) => LiveLineupGroup(
  publicId: id,
  strategyPublicId: strategyId,
  pagePublicId: pageId,
  payload: LineupGroupPayload(
    payloadVersion: 1,
    data: {
      'id': id,
      'origins': [for (var i = 0; i < links; i++) origin('$id-o$i')],
      'landings': [for (var i = 0; i < links; i++) landing('$id-l$i')],
      'links': [
        for (var i = 0; i < links; i++)
          {
            'id': i == 0 ? id : '$id-k$i',
            'originId': '$id-o$i',
            'landingId': '$id-l$i',
            'notes': notes,
          },
      ],
    },
  ),
  sortIndex: sortIndex,
  revision: revision,
);

ElementPayload payloadOf(
  ElementKind kind,
  String id,
  Map<String, Object?> fields,
) => ElementPayload(
  kind: kind,
  payloadVersion: 1,
  data: {'id': id, 'elementType': kind.name, ...fields},
);

LiveElement itemOf(
  ElementKind kind,
  String id, {
  required String pageId,
  Map<String, Object?> fields = const {},
  int sortIndex = 0,
  int revision = 1,
}) => LiveElement(
  publicId: id,
  pagePublicId: pageId,
  payload: payloadOf(kind, id, fields),
  sortIndex: sortIndex,
  revision: revision,
);

UnreadableElement unreadable(String id, {String pageId = 'page-a'}) =>
    UnreadableElement(
      publicId: id,
      pagePublicId: pageId,
      stored: {'publicId': id, 'kind': 'hologram'},
      problem: 'a kind this build does not know',
      reason: const FromNewerBuild(),
    );

StrategyRowSet withStrategy(
  StrategyRowSet rows, {
  String? name,
  String? folderPublicId,
}) => StrategyRowSet(
  strategy: ReadableStrategy(
    publicId: rows.strategy.publicId,
    name: name ?? rows.strategy.name,
    mapData: rows.strategy.mapData,
    folderPublicId: folderPublicId ?? rows.strategy.folderPublicId,
    revision: rows.strategy.revision,
    createdAt: rows.strategy.createdAt,
    updatedAt: rows.strategy.updatedAt,
  ),
  pages: rows.pages,
  settings: rows.settings,
  elements: rows.elements,
  lineupGroups: rows.lineupGroups,
);

final class Generator {
  Generator(int seed) : random = Random(seed);

  final Random random;
  var _next = 0;

  String id(String what) => '$what-${_next++}';

  bool chance(double p) => random.nextDouble() < p;

  T pick<T>(List<T> from) => from[random.nextInt(from.length)];

  int revision() => 1 + random.nextInt(4);

  static const kinds = [
    ElementKind.agent,
    ElementKind.ability,
    ElementKind.drawing,
    ElementKind.text,
    ElementKind.utility,
  ];

  Map<String, Object?> fields(ElementKind kind) => {
    'position': {'dx': random.nextInt(900), 'dy': random.nextInt(500)},
    if (kind == ElementKind.agent) 'type': pick(['jett', 'sova', 'omen']),
    if (kind == ElementKind.text) 'text': pick(['go', 'rotate', 'wait']),
    if (kind != ElementKind.drawing && chance(0.3))
      'caption': pick(['', 'smoke here', 'flash']),
    if (kind == ElementKind.ability && chance(0.2))
      'wallPath': [
        {'dx': 1, 'dy': 2},
      ],
  };

  LiveElement item(String pageId, int sortIndex) {
    final kind = pick(kinds);
    return itemOf(
      kind,
      id('item'),
      pageId: pageId,
      fields: fields(kind),
      sortIndex: sortIndex,
      revision: revision(),
    );
  }

  StrategyRowSet strategy() {
    final pages = <LivePage>[];
    final settingsRows = <PageSettingsRow>[];
    final elements = <ElementRow>[];
    final groups = <LineupGroupRow>[];
    final count = 1 + random.nextInt(4);
    for (var index = 0; index < count; index++) {
      final pageId = id('page');
      final autoNamed = pick<bool?>([true, false, null]);
      pages.add(
        LivePage(
          publicId: pageId,
          strategyPublicId: strategyId,
          name: autoNamed == true ? 'Page ${index + 1}' : id('name'),
          isAutoNamed: autoNamed,
          sortIndex: index,
          isAttack: chance(0.5),
          revision: revision(),
        ),
      );
      settingsRows.add(
        ReadablePageSettings(
          pagePublicId: pageId,
          settings: PageSettings(
            agentSize: 20 + random.nextInt(10).toDouble(),
            abilitySize: 20,
            useNeutralTeamColors: chance(0.5),
          ),
          revision: revision(),
        ),
      );
      for (var i = random.nextInt(6); i > 0; i--) {
        elements.add(item(pageId, elements.length));
      }
      if (chance(0.3)) {
        elements.add(
          DeletedElement(
            publicId: id('gone'),
            pagePublicId: pageId,
            payload: payloadOf(ElementKind.agent, 'gone', {'caption': 'x'}),
            sortIndex: 0,
            revision: revision() + 1,
          ),
        );
      }
      if (chance(0.15)) elements.add(unreadable(id('newer'), pageId: pageId));
      if (chance(0.4)) {
        groups.add(
          lineupGroup(
            id('group'),
            pageId: pageId,
            sortIndex: groups.length,
            revision: revision(),
          ),
        );
      }
    }
    return StrategyRowSet(
      strategy: strategyRow(
        name: id('strategy'),
        mapData: pick(['ascent', 'bind', 'haven']),
        themeProfileId: pick<String?>([null, 'dusk']),
        revision: revision(),
      ),
      pages: pages,
      settings: settingsRows,
      elements: elements,
      lineupGroups: groups,
    );
  }

  StrategyRowSet mutated(StrategyRowSet rows) {
    var strategy = rows.strategy;
    final pages = {
      for (final page in rows.pages.whereType<LivePage>()) page.publicId: page,
    };
    final settingsRows = {
      for (final row in rows.settings) row.pagePublicId: row,
    };
    final elements = {for (final row in rows.elements) row.publicId: row};
    final groups = {for (final row in rows.lineupGroups) row.publicId: row};
    for (var step = 1 + random.nextInt(8); step > 0; step--) {
      final livePages = pages.keys.toList();
      final live = [
        for (final row in elements.values)
          if (row is LiveElement) row,
      ];
      final gone = [
        for (final row in elements.values)
          if (row is DeletedElement && pages.containsKey(row.pagePublicId)) row,
      ];
      final twoGroups = [
        for (final group in groups.values.whereType<LiveLineupGroup>())
          if (_links(group).length > 1) group,
      ];
      switch (random.nextInt(16)) {
        case 0:
          strategy = strategy.rewritten(name: id('renamed'));
        case 1:
          strategy = strategy.rewritten(
            mapData: pick(['lotus', 'pearl']),
            themeProfileId: pick<ValueEdit<String>>([
              const ClearValue(),
              const SetValue('neon'),
            ]),
          );
        case 2:
          final pageId = id('page');
          pages[pageId] = LivePage(
            publicId: pageId,
            strategyPublicId: strategyId,
            name: 'Page ${pages.length + 1}',
            isAutoNamed: true,
            sortIndex: random.nextInt(pages.length + 1) - 1,
            isAttack: chance(0.5),
            revision: 1,
          );
          settingsRows[pageId] = settings(pageId);
          elements[id('x')] = item(pageId, 0);
        case 3 when pages.length > 1:
          final gone = pick(livePages);
          pages.remove(gone);
          settingsRows.remove(gone);
          elements.removeWhere(
            (_, row) => row.pagePublicId == gone && row is! UnreadableElement,
          );
          groups.removeWhere((_, row) => row.pagePublicId == gone);
        case 4:
          final page = pages[pick(livePages)]!;
          pages[page.publicId] = page.placed(
            name: page.name,
            sortIndex: random.nextInt(pages.length + 2) - 1,
          );
        case 5:
          final page = pages[pick(livePages)]!;
          pages[page.publicId] = page.patched(
            name: id('name'),
            isAutoNamed: chance(0.5),
            isAttack: !page.isAttack,
          );
        case 6:
          final pageId = pick(livePages);
          settingsRows[pageId] = settings(
            pageId,
            value: PageSettings(
              agentSize: 40,
              abilitySize: 30,
              useNeutralTeamColors: chance(0.5),
            ),
          );
        case 7:
          final pageId = pick(livePages);
          final added = item(pageId, random.nextInt(10));
          elements[added.publicId] = added;
        case 8 when live.isNotEmpty:
          final row = pick(live);
          elements[row.publicId] = row.rewritten(
            deleted: false,
            payload: row.payload.withData({
              ...row.payload.data.toMap(),
              'position': {'dx': random.nextInt(900), 'dy': 7},
            }),
            sortIndex: random.nextInt(10),
          );
        case 9 when live.isNotEmpty:
          final row = pick(live);
          elements[row.publicId] = row.rewritten(
            deleted: false,
            pagePublicId: pick(livePages),
          );
        case 10 when live.isNotEmpty:
          elements.remove(pick(live).publicId);
        case 11 when live.isNotEmpty:
          final row = pick(live);
          final data = row.payload.data.toMap();
          if (data.containsKey('caption')) {
            data.remove('caption');
          } else if (row.payload.kind != ElementKind.drawing) {
            data['caption'] = 'new note';
          }
          elements[row.publicId] = row.rewritten(
            deleted: false,
            payload: row.payload.withData(data),
          );
        case 12:
          final pageId = pick(livePages);
          final group = lineupGroup(
            id('group'),
            pageId: pageId,
            sortIndex: random.nextInt(3),
            links: 1 + random.nextInt(2),
          );
          groups[group.publicId] = group;
        case 13 when groups.values.any((row) => row is LiveLineupGroup):
          final group = pick(
            groups.values.whereType<LiveLineupGroup>().toList(),
          );
          if (chance(0.5)) {
            groups.remove(group.publicId);
          } else {
            groups[group.publicId] = lineupGroup(
              group.publicId,
              pageId: chance(0.7) ? group.pagePublicId : pick(livePages),
              sortIndex: random.nextInt(3),
              notes: id('notes'),
              links: 1 + random.nextInt(2),
            );
          }
        case 14 when gone.isNotEmpty:
          final row = pick(gone);
          elements[row.publicId] = row.rewritten(
            deleted: false,
            payload: payloadOf(ElementKind.agent, row.publicId, {
              'type': 'sova',
            }),
          );
        case 15 when twoGroups.isNotEmpty:
          final from = pick(twoGroups);
          final to = groups.values.whereType<LiveLineupGroup>().firstWhere(
            (group) =>
                group.publicId != from.publicId &&
                group.pagePublicId == from.pagePublicId,
            orElse: () => from,
          );
          if (identical(to, from)) break;
          final moved = _links(from).last;
          groups[from.publicId] = _withLinks(
            from,
            _links(from).take(_links(from).length - 1).toList(),
          );
          groups[to.publicId] = _withLinks(to, [..._links(to), moved]);
        case _:
          break;
      }
    }
    final ordered = pages.values.toList()
      ..sort(
        (a, b) => switch (a.sortIndex.compareTo(b.sortIndex)) {
          0 => a.publicId.compareTo(b.publicId),
          final order => order,
        },
      );
    return StrategyRowSet(
      strategy: strategy,
      pages: [
        for (final (index, page) in ordered.indexed)
          chance(0.5) ? page : page.placed(name: page.name, sortIndex: index),
      ],
      settings: settingsRows.values,
      elements: elements.values.where(
        (row) =>
            row is! UnreadableElement || pages.containsKey(row.pagePublicId),
      ),
      lineupGroups: groups.values.whereType<LiveLineupGroup>(),
    );
  }
}

final _future = jsonObject({
  'fromALaterBuild': {'level': 7},
});

StrategyRowSet withUnknownFields(StrategyRowSet rows) => StrategyRowSet(
  strategy: ReadableStrategy(
    publicId: rows.strategy.publicId,
    name: rows.strategy.name,
    mapData: rows.strategy.mapData,
    folderPublicId: rows.strategy.folderPublicId,
    themeProfileId: rows.strategy.themeProfileId,
    themeOverridePalette: rows.strategy.themeOverridePalette,
    revision: rows.strategy.revision,
    createdAt: rows.strategy.createdAt,
    updatedAt: rows.strategy.updatedAt,
    unknownFields: _future,
  ),
  pages: [
    for (final page in rows.pages)
      if (page case LivePage())
        LivePage(
          publicId: page.publicId,
          strategyPublicId: page.strategyPublicId,
          name: page.name,
          isAutoNamed: page.isAutoNamed,
          sortIndex: page.sortIndex,
          isAttack: page.isAttack,
          revision: page.revision,
          unknownFields: _future,
        )
      else
        page,
  ],
  settings: [
    for (final row in rows.settings)
      if (row case ReadablePageSettings(:final settings?))
        ReadablePageSettings(
          pagePublicId: row.pagePublicId,
          settings: PageSettings.keeping(
            agentSize: settings.agentSize,
            abilitySize: settings.abilitySize,
            useNeutralTeamColors: settings.useNeutralTeamColors,
            unknownFields: _future.toMap(),
          ),
          revision: row.revision,
          unknownFields: _future,
        )
      else
        row,
  ],
  elements: [
    for (final row in rows.elements)
      if (row case LiveElement(:final payload))
        LiveElement(
          publicId: row.publicId,
          pagePublicId: row.pagePublicId,
          payload: ElementPayload(
            kind: payload.kind,
            payloadVersion: payload.payloadVersion,
            data: {
              ...payload.data.toMap(),
              'fromALaterBuild': {'x': 1},
            },
            unknownFields: _future.toMap(),
          ),
          sortIndex: row.sortIndex,
          revision: row.revision,
          unknownFields: _future,
        )
      else
        row,
  ],
  lineupGroups: [
    for (final row in rows.lineupGroups)
      if (row case LiveLineupGroup(:final payload))
        LiveLineupGroup(
          publicId: row.publicId,
          strategyPublicId: row.strategyPublicId,
          pagePublicId: row.pagePublicId,
          payload: LineupGroupPayload(
            payloadVersion: payload.payloadVersion,
            data: {
              ...payload.data.toJson(),
              'fromALaterBuild': true,
              'links': [
                for (final link in payload.data.toJson()['links']! as List)
                  {...link as Map<String, Object?>, 'laterNote': 'kept'},
              ],
            },
            unknownFields: _future.toMap(),
          ),
          sortIndex: row.sortIndex,
          revision: row.revision,
          unknownFields: _future,
        )
      else
        row,
  ],
);

typedef _Link = (
  Map<String, Object?> origin,
  Map<String, Object?> landing,
  Map<String, Object?> link,
);

List<_Link> _links(LiveLineupGroup group) {
  final data = group.payload.data.toJson();
  final origins = {
    for (final item in data['origins']! as List)
      (item as Map<String, Object?>)['id']: item,
  };
  final landings = {
    for (final item in data['landings']! as List)
      (item as Map<String, Object?>)['id']: item,
  };
  return [
    for (final link in (data['links']! as List).cast<Map<String, Object?>>())
      (origins[link['originId']]!, landings[link['landingId']]!, link),
  ];
}

LiveLineupGroup _withLinks(LiveLineupGroup group, List<_Link> links) =>
    LiveLineupGroup(
      publicId: group.publicId,
      strategyPublicId: group.strategyPublicId,
      pagePublicId: group.pagePublicId,
      payload: LineupGroupPayload(
        payloadVersion: group.payload.payloadVersion,
        data: {
          ...group.payload.data.toJson(),
          'origins': [for (final link in links) link.$1],
          'landings': [for (final link in links) link.$2],
          'links': [for (final link in links) link.$3],
        },
      ),
      sortIndex: group.sortIndex,
      revision: group.revision,
    );
