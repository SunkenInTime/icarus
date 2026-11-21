import 'dart:convert';
import 'dart:math';

import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/library_rows/page_items.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_rows/strategy_for_save.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/strategy_diff_check.dart';

StrategyRowSet rowsOf(StrategyData strategy) =>
    switch (strategyToRows(strategy)) {
      StrategyRowsMade(:final rows) => rows,
      StrategyRowsRefused(:final problems) => fail('$problems'),
    };

StrategyRowSet targetFor(StrategyRowSet stored, StrategyData model) =>
    switch (strategyToRowsOver(stored, model)) {
      StrategyRowsMade(:final rows) => rows,
      StrategyRowsRefused(:final problems) => fail('$problems'),
    };

final class Library {
  Library._(this.storage, this.store, this.id, this.map);

  final MemoryStorage storage;
  final LibraryStore store;
  final String id;
  final MapValue map;

  static Future<Library> holding(StrategyRowSet rows, MapValue map) async {
    final storage = MemoryStorage();
    final store = await _open(storage, map);
    switch (await store.editLibrary([AddStrategy(rows)])) {
      case Saved():
        break;
      case final other:
        fail('not added: $other');
    }
    return Library._(storage, store, rows.strategy.publicId, map);
  }

  static Future<LibraryStore> _open(
          MemoryStorage storage, MapValue map) async =>
      switch (await LibraryStore.open(
        MemoryEngine(storage),
        canRead: CanRead(
          element: (payload) => canReadElementPayload(payload, map),
          lineupGroup: (_) => true,
        ),
      )) {
        StoreOpened(:final store) => store,
        StoreNotOpened(:final problem) => fail('$problem'),
      };

  Map<String, String> get stored => {...storage.contents[strategyArea(id)]!};

  Future<StrategyRowSet> rows() async {
    final content = switch (await store.readStrategy(id)) {
      Found(:final value) => value,
      final other => fail('$other'),
    };
    final elements = <ElementRow>[];
    final groups = <LineupGroupRow>[];
    for (final page in content.pages) {
      final onPage = switch (await store.readPage(id, page.publicId)) {
        Found(:final value) => value,
        final other => fail('$other'),
      };
      elements.addAll(onPage.elements);
      groups.addAll(onPage.lineupGroups);
    }
    return StrategyRowSet(
      strategy: content.strategy as ReadableStrategy,
      pages: content.pages,
      settings: content.settings.values,
      elements: elements,
      lineupGroups: groups,
    );
  }

  Future<StrategyData> model() async {
    final rows = await this.rows();
    return switch (strategyFromRows(rows)) {
      StrategyDataMade(:final strategy) => strategy,
      StrategyDataRefused(:final problems) => fail('$problems'),
    };
  }

  Future<List<StrategyOp>> save(StrategyData model) async {
    final stored = await rows();
    final ops = switch (diffStrategy(
      stored,
      targetFor(stored, model),
      editId: 'save-${DateTime.now().microsecondsSinceEpoch}',
    )) {
      DiffOps(:final ops) => ops,
      DiffRefused(:final refusal) => fail('refused: $refusal'),
    };
    switch (await store.commitAll(id, ops)) {
      case Saved() || NothingToSave():
        break;
      case final other:
        fail('not saved: $other');
    }
    return ops;
  }
}

StrategyPage pageOf(
  String id,
  int index, {
  List<PlacedAgentNode> agents = const [],
  List<PlacedUtility> utilities = const [],
  LineUpGraph lineups = LineUpGraph.empty,
}) =>
    StrategyPage(
      id: id,
      name: 'Page ${index + 1}',
      isAutoNamed: true,
      sortIndex: index,
      drawingData: const [],
      agentData: agents,
      abilityData: const [],
      textData: const [],
      imageData: const [],
      utilityData: utilities,
      isAttack: true,
      settings: StrategySettings(),
      lineUpOrigins: lineups.origins,
      lineUpLandings: lineups.landings,
      lineUpLinks: lineups.links,
    );

StrategyData strategyOf(List<StrategyPage> pages,
        {MapValue map = MapValue.haven}) =>
    StrategyData(
      id: 'saved',
      name: 'Retake',
      mapData: map,
      versionNumber: Settings.versionNumber,
      lastEdited: DateTime.utc(2026, 11, 1),
      createdAt: DateTime.utc(2026, 11, 1),
      folderID: null,
      pages: pages,
    );

PlacedAgent agent(String id, double x) =>
    PlacedAgent(id: id, type: AgentType.jett, position: Offset(x, 200));

PlacedAbility recon(String id, double x) => PlacedAbility(
      id: id,
      data: AgentData.agents[AgentType.sova]!.abilities.first,
      position: Offset(x, 300),
    );

LineUpOrigin origin(String id) => LineUpOrigin(
      id: id,
      agent: PlacedAgent(
        id: '$id-agent',
        type: AgentType.sova,
        position: const Offset(600, 400),
      ),
    );

LineUpLanding landing(String id, double x) =>
    LineUpLanding(id: id, ability: recon('$id-ability', x));

StrategyData withPages(StrategyData model, List<StrategyPage> pages) =>
    model.copyWith(pages: pages);

Map<String, Object?> groupData(StrategyRowSet rows, String groupId) =>
    switch (rows.lineupGroup(groupId)) {
      LiveLineupGroup(:final payload) => payload.data.toJson(),
      final other => fail('$groupId is not a live group: $other'),
    };

Map<String, Object?> later(Map<String, Object?> json) => {
      ...json,
      'fromALaterBuild': {'level': 7},
    };

StrategyRowSet storedByALaterBuild(StrategyRowSet rows) => StrategyRowSet(
      strategy: rows.strategy,
      pages: rows.pages,
      settings: rows.settings,
      elements: [
        for (final row in rows.elements)
          if (row case LiveElement(:final payload))
            LiveElement(
              publicId: row.publicId,
              pagePublicId: row.pagePublicId,
              payload: ElementPayload(
                kind: payload.kind,
                payloadVersion: payload.data['type'] == 'customCircle'
                    ? 1
                    : payload.payloadVersion,
                data: later(payload.data.toJson()),
                unknownFields: {'envelopeFromALaterBuild': true},
              ),
              sortIndex: row.sortIndex,
              revision: row.revision,
              unknownFields: jsonObject({'rowFromALaterBuild': 1}),
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
                  ...later(payload.data.toJson()),
                  for (final collection in ['origins', 'links'])
                    collection: [
                      for (final item
                          in payload.data.toJson()[collection]! as List)
                        later(item as Map<String, Object?>),
                    ],
                  'landings': [
                    for (final item
                        in payload.data.toJson()['landings']! as List)
                      {
                        ...item as Map<String, Object?>,
                        'ability':
                            later(item['ability']! as Map<String, Object?>),
                      },
                  ],
                },
                unknownFields: {'envelopeFromALaterBuild': true},
              ),
              sortIndex: row.sortIndex,
              revision: row.revision,
              unknownFields: jsonObject({'rowFromALaterBuild': 1}),
            )
          else
            row,
      ],
    );

final class Editor {
  Editor(int seed) : random = Random(seed);

  final Random random;
  var _next = 0;

  String id(String what) => '$what-${_next++}';

  T pick<T>(List<T> from) => from[random.nextInt(from.length)];

  StrategyData edit(StrategyData model) {
    final pages = [...model.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    final page = pick(pages);
    StrategyData replacing(StrategyPage changed) => withPages(model, [
          for (final each in model.pages) each.id == page.id ? changed : each,
        ]);
    final graph = page.lineUpGraph;
    switch (random.nextInt(9)) {
      case 0 when page.agentData.isNotEmpty:
        final moved = pick(page.agentData) as PlacedAgent;
        return replacing(page.copyWith(agentData: [
          for (final each in page.agentData)
            each.id == moved.id
                ? PlacedAgent(
                    id: moved.id,
                    type: moved.type,
                    position: moved.position + const Offset(13, 7),
                  )
                : each,
        ]));
      case 1:
        return replacing(page.copyWith(
          agentData: [...page.agentData, agent(id('agent'), 50)],
        ));
      case 2 when page.agentData.isNotEmpty:
        final gone = pick(page.agentData);
        return replacing(page.copyWith(agentData: [
          for (final each in page.agentData)
            if (each.id != gone.id) each,
        ]));
      case 3:
        return withPages(model, [
          ...model.pages,
          page.copyWith(
            id: id('copy'),
            name: 'Copy',
            isAutoNamed: false,
            sortIndex: pages.last.sortIndex + 1,
          ),
        ]);
      case 4 when pages.length > 1:
        return withPages(model, [
          for (final each in model.pages)
            if (each.id != page.id) each,
        ]);
      case 5 when graph.links.isNotEmpty:
        final gone = pick(graph.links);
        final links = [
          for (final link in graph.links)
            if (link.id != gone.id) link,
        ];
        return replacing(page.copyWith(
          lineUpGraph: LineUpGraph(
            origins: [
              for (final each in graph.origins)
                if (links.any((link) => link.originId == each.id)) each,
            ],
            landings: [
              for (final each in graph.landings)
                if (links.any((link) => link.landingId == each.id)) each,
            ],
            links: links,
          ),
        ));
      case 6 when graph.origins.isNotEmpty:
        final at = pick(graph.origins);
        final spot = id('landing');
        return replacing(page.copyWith(
          lineUpGraph: LineUpGraph(
            origins: graph.origins,
            landings: [...graph.landings, landing(spot, 820)],
            links: [
              ...graph.links,
              LineUpLink(id: id('link'), originId: at.id, landingId: spot),
            ],
          ),
        ));
      case 7:
        return model.copyWith(name: id('name'));
      case 8 when graph.landings.isNotEmpty:
        final moved = pick(graph.landings);
        return replacing(page.copyWith(
          lineUpGraph: LineUpGraph(
            origins: graph.origins,
            landings: [
              for (final each in graph.landings)
                each.id == moved.id
                    ? LineUpLanding(
                        id: each.id,
                        ability: recon(
                          each.ability.id,
                          each.ability.position.dx + 5,
                        ),
                      )
                    : each,
            ],
            links: graph.links,
          ),
        ));
      case _:
        return model;
    }
  }
}

Map<String, String> itemJson(StrategyPage page) => {
      for (final item in pageItemsOf(page))
        item.id: switch (item.payload) {
          Read(:final value) => jsonEncode(value.toJson()),
          CouldNotRead() => '',
        },
    };

Map<String, String> lineupJson(StrategyPage page) => {
      for (final item in page.lineUpOrigins) 'o:${item.id}': jsonEncode(item),
      for (final item in page.lineUpLandings) 'l:${item.id}': jsonEncode(item),
      for (final item in page.lineUpLinks) 'k:${item.id}': jsonEncode(item),
    };

Set<String> untouchedNames(
  StrategyRowSet stored,
  StrategyData before,
  StrategyData after,
) {
  final names = <String>{};
  final afterPages = {for (final page in after.pages) page.id: page};
  for (final page in before.pages) {
    final now = afterPages[page.id];
    if (now == null) continue;
    final was = itemJson(page);
    final is_ = itemJson(now);
    for (final row in stored.elementsOn(page.id)) {
      if (row case LiveElement(:final payload, :final publicId)) {
        final itemId = payload.data['id'];
        if (was[itemId] != null && was[itemId] == is_[itemId]) {
          names.add('content/${digestOf(page.id)}/e/${digestOf(publicId)}');
        }
      }
    }
    final wasLineups = lineupJson(page);
    final isLineups = lineupJson(now);
    for (final row in stored.lineupGroupsOn(page.id)) {
      if (row case LiveLineupGroup(:final payload, :final publicId)) {
        final data = payload.data.toJson();
        final keys = {
          for (final item in data['origins']! as List)
            'o:${(item as Map)['id']}',
          for (final item in data['landings']! as List)
            'l:${(item as Map)['id']}',
          for (final item in data['links']! as List) 'k:${(item as Map)['id']}',
        };
        final same = keys.every(
          (key) => wasLineups[key] != null && wasLineups[key] == isLineups[key],
        );
        final joined = now.lineUpLinks.any(
          (link) =>
              !keys.contains('k:${link.id}') &&
              (keys.contains('o:${link.originId}') ||
                  keys.contains('l:${link.landingId}')),
        );
        if (same && !joined) {
          names.add('content/${digestOf(page.id)}/l/${digestOf(publicId)}');
        }
      }
    }
  }
  return names;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => appProviderContainer = ProviderContainer());
  tearDownAll(() => appProviderContainer.dispose());

  test('deleting the original of a copied page leaves its content in the trash',
      () async {
    final first = pageOf(
      'page-1',
      0,
      agents: [agent('jett', 100), agent('sova', 200), agent('omen', 300)],
      lineups: LineUpGraph(
        origins: [origin('o')],
        landings: [landing('l', 500)],
        links: [LineUpLink(id: 'k', originId: 'o', landingId: 'l')],
      ),
    );
    final library = await Library.holding(
      rowsOf(strategyOf([first])),
      MapValue.haven,
    );
    final model = await library.model();
    final copy = model.pages.single.copyWith(
      id: 'page-2',
      name: 'Page 2',
      sortIndex: 1,
    );
    await library.save(withPages(model, [...model.pages, copy]));
    final withCopy = await library.model();
    await library.save(
      withPages(withCopy, [
        for (final page in withCopy.pages)
          if (page.id == 'page-2') page.copyWith(sortIndex: 0),
      ]),
    );

    final rows = await library.rows();
    expect(rows.page('page-1'), isA<TrashedPage>());
    expect(
      rows.elementsOn('page-1').whereType<LiveElement>(),
      hasLength(3),
      reason: 'the trashed page keeps its agents',
    );
    expect(
      rows.lineupGroupsOn('page-1').whereType<LiveLineupGroup>(),
      hasLength(1),
      reason: 'the trashed page keeps its lineups',
    );
    expect(rows.elementsOn('page-2').whereType<LiveElement>(), hasLength(3));
  });

  test('deleting a copied page leaves the original exactly as stored',
      () async {
    final library = await Library.holding(
      storedByALaterBuild(
        rowsOf(
          strategyOf([
            pageOf('page-1', 0, agents: [agent('jett', 100)]),
          ]),
        ),
      ),
      MapValue.haven,
    );
    final model = await library.model();
    await library.save(
      withPages(model, [
        ...model.pages,
        model.pages.single.copyWith(id: 'page-2', name: 'Copy', sortIndex: 1),
      ]),
    );
    final original = library.stored;
    final withCopy = await library.model();
    final ops = await library.save(
      withPages(withCopy, [
        for (final page in withCopy.pages)
          if (page.id == 'page-1') page,
      ]),
    );
    expect(ops.map((op) => op.type), [OpType.pageDelete]);
    final after = library.stored;
    for (final MapEntry(:key, :value) in original.entries) {
      if (key.startsWith('content/${digestOf('page-1')}/')) {
        expect(after[key], value);
      }
    }
    expect(
      (await library.rows()).elementsOn('page-2').whereType<LiveElement>(),
      hasLength(1),
      reason: 'the trashed copy keeps its agent',
    );
  });

  test('deleting the only lineup of a group deletes that group alone',
      () async {
    final graph = LineUpGraph(
      origins: [origin('o1'), origin('o2')],
      landings: [landing('l1', 500), landing('l2', 600)],
      links: [
        LineUpLink(id: 'k1', originId: 'o1', landingId: 'l1'),
        LineUpLink(id: 'k2', originId: 'o2', landingId: 'l2'),
      ],
    );
    final library = await Library.holding(
      storedByALaterBuild(
          rowsOf(strategyOf([pageOf('page-1', 0, lineups: graph)]))),
      MapValue.haven,
    );
    final before = library.stored;
    final model = await library.model();
    final page = model.pages.single;
    final ops = await library.save(
      withPages(model, [
        page.copyWith(
          lineUpGraph: LineUpGraph(
            origins: [origin('o2')],
            landings: [
              for (final item in page.lineUpLandings)
                if (item.id == 'l2') item,
            ],
            links: [
              for (final link in page.lineUpLinks)
                if (link.id == 'k2') link,
            ],
          ),
        ),
      ]),
    );
    expect(
      [
        for (final op in ops)
          if (op case LineupGroupDeleteOp(:final lineupPublicId))
            lineupPublicId,
      ],
      ['k1'],
    );
    expect(ops, hasLength(1));
    final name = 'content/${digestOf('page-1')}/l/${digestOf('k2')}';
    expect(library.stored[name], before[name]);
  });

  test('renaming a strategy leaves an older custom circle exactly as stored',
      () async {
    final circle = PlacedUtility(
      id: 'circle',
      type: UtilityType.customCircle,
      position: const Offset(410, 270),
      customDiameter: 14,
      customColorValue: 0xFF22C55E,
      customOpacityPercent: 30,
    );
    final made = rowsOf(strategyOf([
      pageOf('page-1', 0, utilities: [circle])
    ]));
    final old = made.elements.single as LiveElement;
    final stored = StrategyRowSet(
      strategy: made.strategy,
      pages: made.pages,
      settings: made.settings,
      elements: [
        LiveElement(
          publicId: old.publicId,
          pagePublicId: old.pagePublicId,
          payload: ElementPayload(
            kind: ElementKind.utility,
            payloadVersion: 1,
            data: {
              ...circle.toJson(),
              'fromALaterBuild': {'x': 1}
            },
            unknownFields: {'envelopeFromALaterBuild': true},
          ),
          sortIndex: old.sortIndex,
          revision: old.revision,
        ),
      ],
    );
    final library = await Library.holding(stored, MapValue.haven);
    final before = library.stored;
    final model = await library.model();

    final ops = await library.save(model.copyWith(name: 'Renamed'));

    expect(ops.map((op) => op.type), [OpType.strategyPatch]);
    final after = library.stored;
    for (final MapEntry(:key, :value) in before.entries) {
      if (key.startsWith('content/')) {
        expect(after[key], value, reason: 'the circle row is unchanged');
      }
    }
  });

  group('A lineup group', () {
    final graph = LineUpGraph(
      origins: [origin('o')],
      landings: [landing('l1', 500), landing('l2', 700)],
      links: [
        LineUpLink(id: 'k1', originId: 'o', landingId: 'l1'),
        LineUpLink(id: 'k2', originId: 'o', landingId: 'l2'),
      ],
    );

    Future<Library> storedWithUnknownFields() async {
      final made = rowsOf(strategyOf([pageOf('page-1', 0, lineups: graph)]));
      final group = made.lineupGroups.single as LiveLineupGroup;
      final data = group.payload.data.toJson();
      final stored = StrategyRowSet(
        strategy: made.strategy,
        pages: made.pages,
        settings: made.settings,
        lineupGroups: [
          LiveLineupGroup(
            publicId: group.publicId,
            strategyPublicId: group.strategyPublicId,
            pagePublicId: group.pagePublicId,
            payload: LineupGroupPayload(
              payloadVersion: group.payload.payloadVersion,
              data: {
                ...data,
                'links': [
                  for (final link in data['links']! as List)
                    {...link as Map<String, Object?>, 'laterNote': 'kept'},
                ],
                'landings': [
                  for (final item in data['landings']! as List)
                    {
                      ...item as Map<String, Object?>,
                      'ability': {
                        ...item['ability']! as Map<String, Object?>,
                        'laterGlow': 3,
                      },
                    },
                ],
              },
            ),
            sortIndex: group.sortIndex,
            revision: group.revision,
          ),
        ],
      );
      return Library.holding(stored, MapValue.haven);
    }

    test('keeps its id and its fields when the lineup that named it goes',
        () async {
      final library = await storedWithUnknownFields();
      final model = await library.model();
      final page = model.pages.single;
      await library.save(
        withPages(model, [
          page.copyWith(
            lineUpGraph: LineUpGraph(
              origins: page.lineUpOrigins,
              landings: [
                for (final item in page.lineUpLandings)
                  if (item.id != 'l1') item,
              ],
              links: [
                for (final link in page.lineUpLinks)
                  if (link.id != 'k1') link,
              ],
            ),
          ),
        ]),
      );
      final data = groupData(await library.rows(), 'k1');
      expect(
        [for (final link in data['links']! as List) (link as Map)['laterNote']],
        ['kept'],
      );
      expect(
        [
          for (final item in data['landings']! as List)
            ((item as Map)['ability'] as Map)['laterGlow'],
        ],
        [3],
      );
    });

    test('keeps fields inside an ability the user moved', () async {
      final library = await storedWithUnknownFields();
      final model = await library.model();
      final page = model.pages.single;
      await library.save(
        withPages(model, [
          page.copyWith(
            lineUpGraph: LineUpGraph(
              origins: page.lineUpOrigins,
              landings: [
                for (final item in page.lineUpLandings)
                  item.id == 'l2' ? landing('l2', 750) : item,
              ],
              links: page.lineUpLinks,
            ),
          ),
        ]),
      );
      final data = groupData(await library.rows(), 'k1');
      final moved = (data['landings']! as List)
          .cast<Map<String, Object?>>()
          .firstWhere((item) => item['id'] == 'l2');
      expect((moved['ability']! as Map)['laterGlow'], 3);
    });

    test('keeps two lineups added at once in the order they were placed',
        () async {
      final library = await Library.holding(
        rowsOf(strategyOf([pageOf('page-1', 0, lineups: graph)])),
        MapValue.haven,
      );
      final model = await library.model();
      final page = model.pages.single;
      await library.save(
        withPages(model, [
          page.copyWith(
            lineUpGraph: LineUpGraph(
              origins: page.lineUpOrigins,
              landings: [
                ...page.lineUpLandings,
                landing('lz', 800),
                landing('lm', 900),
              ],
              links: [
                ...page.lineUpLinks,
                LineUpLink(id: 'z', originId: 'o', landingId: 'lz'),
                LineUpLink(id: 'm', originId: 'o', landingId: 'lm'),
              ],
            ),
          ),
        ]),
      );
      final data = groupData(await library.rows(), 'k1');
      expect(
        [for (final link in data['links']! as List) (link as Map)['id']],
        ['k1', 'k2', 'z', 'm'],
      );
      expect(
        [for (final item in data['landings']! as List) (item as Map)['id']],
        ['l1', 'l2', 'lz', 'lm'],
      );
    });
  });

  test('after any edits, what the user did not touch keeps its stored bytes',
      () async {
    final start = strategyOf([
      pageOf(
        'page-1',
        0,
        agents: [agent('jett', 100), agent('sova', 200)],
        utilities: [
          PlacedUtility(
            id: 'circle',
            type: UtilityType.customCircle,
            position: const Offset(410, 270),
            customDiameter: 14,
            customColorValue: 0xFF22C55E,
            customOpacityPercent: 30,
          ),
        ],
        lineups: LineUpGraph(
          origins: [origin('o1'), origin('o2')],
          landings: [
            landing('l1', 500),
            landing('l2', 600),
            landing('l3', 700)
          ],
          links: [
            LineUpLink(id: 'k1', originId: 'o1', landingId: 'l1'),
            LineUpLink(id: 'k2', originId: 'o1', landingId: 'l2'),
            LineUpLink(id: 'k3', originId: 'o2', landingId: 'l3'),
          ],
        ),
      ),
      pageOf('page-2', 1, agents: [agent('omen', 300)]),
    ]);
    var saves = 0;
    var untouchedChecked = 0;
    for (var seed = 0; seed < 30; seed++) {
      final library = await Library.holding(
        storedByALaterBuild(rowsOf(start)),
        MapValue.haven,
      );
      final editor = Editor(seed);
      for (var step = 0; step < 8; step++) {
        final before = await library.model();
        final storedRows = await library.rows();
        final storedBytes = library.stored;
        final after = editor.edit(before);
        final target = targetFor(storedRows, after);
        final ops = await library.save(after);
        saves++;
        final readBack = await library.rows();
        expect(
          switch (checkReached(storedRows, target, readBack)) {
            DiffReached() => 'reached',
            DiffMissed(:final what) => what,
          },
          'reached',
          reason: 'seed $seed step $step',
        );
        final untouched = untouchedNames(storedRows, before, after);
        untouchedChecked += untouched.length;
        final bytes = library.stored;
        for (final name in untouched) {
          expect(
            bytes[name],
            storedBytes[name],
            reason: 'seed $seed step $step: $name was not touched',
          );
        }
        final named = {
          for (final op in ops)
            switch (op) {
              ElementPatchOp(:final elementPublicId) ||
              ElementDeleteOp(:final elementPublicId) =>
                elementPublicId,
              LineupGroupPatchOp(:final lineupPublicId) ||
              LineupGroupDeleteOp(:final lineupPublicId) =>
                lineupPublicId,
              _ => null,
            },
        };
        for (final name in untouched) {
          final id = [
            for (final row in [
              ...storedRows.elements,
              ...storedRows.lineupGroups,
            ])
              if (name.endsWith('/${digestOf(row.key.id)}')) row.key.id,
          ].first;
          expect(named, isNot(contains(id)), reason: 'seed $seed step $step');
        }
      }
    }
    expect(saves, 240);
    expect(untouchedChecked, greaterThan(1000));
  });
}
