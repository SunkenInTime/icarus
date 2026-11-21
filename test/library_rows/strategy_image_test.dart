import 'dart:io';
import 'dart:math';

import 'package:collection/collection.dart';
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
import 'package:icarus/library_rows/strategy_comparison.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/sqlite_storage.dart';

StrategyRowSet rowsOf(StrategyData strategy) =>
    switch (strategyToRows(strategy)) {
      StrategyRowsMade(:final rows) => rows,
      StrategyRowsRefused(:final problems) => fail('$problems'),
    };

CanRead canReadOn(MapValue map) => CanRead(
      element: (payload) => canReadElementPayload(payload, map),
      lineupGroup: (_) => true,
    );

Future<LibraryStore> openOn(StorageEngine engine, MapValue map) async =>
    switch (await LibraryStore.open(engine, canRead: canReadOn(map))) {
      StoreOpened(:final store) => store,
      StoreNotOpened(:final problem) => fail('$problem'),
    };

Future<Map<String, Map<String, String>>> imageOf(
  StrategyRowSet rows,
  MapValue map,
) async {
  final storage = MemoryStorage();
  final store = await openOn(MemoryEngine(storage), map);
  switch (await store.editLibrary([AddStrategy(rows)])) {
    case Saved():
      break;
    case final other:
      fail('not added: $other');
  }
  await store.close();
  return storage.contents;
}

Future<StrategyData> readBack(LibraryStore store, String id) async {
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
  return switch (strategyFromRows(
    StrategyRowSet(
      strategy: content.strategy as ReadableStrategy,
      pages: content.pages,
      settings: content.settings.values,
      elements: elements,
      lineupGroups: groups,
    ),
  )) {
    StrategyDataMade(:final strategy) => strategy,
    StrategyDataRefused(:final problems) => fail('$problems'),
  };
}

final class Saves {
  var steps = 0;
  var lineupOrderOnly = 0;

  Future<void> check(
    LibraryStore store,
    MemoryStorage storage,
    StrategyData model,
    String where,
  ) async {
    final rows = rowsOf(model);
    switch (await store.putStrategy(rows)) {
      case Saved() || NothingToSave():
        break;
      case final other:
        fail('$where: not saved: $other');
    }
    steps++;
    expect(
      const DeepCollectionEquality().equals(
        storage.contents,
        await imageOf(rows, model.mapData),
      ),
      isTrue,
      reason: '$where: the stored bytes are the image of the model',
    );
    final differences = strategyDifferences(
      model,
      await readBack(store, model.id),
    );
    expect(
      [
        for (final difference in differences)
          if (difference.kind != DifferenceKind.lineupOrder) '$difference',
      ],
      isEmpty,
      reason: '$where: what is read back is the model',
    );
    if (differences.isNotEmpty) lineupOrderOnly++;
  }
}

PlacedAbility reconAt(String id, Offset at) => PlacedAbility(
      id: id,
      data: AgentData.agents[AgentType.sova]!.abilities.first,
      position: at,
    );

StrategyPage editPage(
  StrategyData strategy,
  String pageId,
  StrategyPage Function(StrategyPage page) edit,
) =>
    [
      for (final page in strategy.pages)
        if (page.id == pageId) edit(page),
    ].single;

StrategyData withPage(
  StrategyData strategy,
  String pageId,
  StrategyPage Function(StrategyPage page) edit,
) =>
    strategy.copyWith(
      pages: [
        for (final page in strategy.pages)
          page.id == pageId ? edit(page) : page,
      ],
    );

List<StrategyData> scriptedSession() {
  final note = PlacedText(id: 'note', position: const Offset(40, 50))
    ..text = 'wait for flash'
    ..caption = 'call it';
  final first = StrategyPage(
    id: 'page-1',
    name: 'Page 1',
    isAutoNamed: true,
    sortIndex: 0,
    drawingData: const [],
    agentData: [
      PlacedAgent(
        id: 'jett',
        type: AgentType.jett,
        position: const Offset(1, 2),
      ),
    ],
    abilityData: [reconAt('recon', const Offset(300, 300))],
    textData: [note],
    imageData: const [],
    utilityData: const [],
    isAttack: true,
    settings: StrategySettings(),
    lineUpOrigins: [
      LineUpOrigin(
        id: 'origin',
        agent: PlacedAgent(
          id: 'origin-agent',
          type: AgentType.sova,
          position: const Offset(600, 400),
        ),
      ),
    ],
    lineUpLandings: [
      LineUpLanding(
        id: 'landing',
        ability: reconAt('landing-ability', const Offset(700, 200)),
      ),
    ],
    lineUpLinks: [
      LineUpLink(id: 'link', originId: 'origin', landingId: 'landing'),
    ],
  );
  final states = <StrategyData>[
    StrategyData(
      id: 'session',
      name: 'Retake B',
      mapData: MapValue.ascent,
      versionNumber: Settings.versionNumber,
      lastEdited: DateTime.utc(2026, 11, 1),
      createdAt: DateTime.utc(2026, 11, 1),
      folderID: null,
      pages: [first],
    ),
  ];
  void step(StrategyData Function(StrategyData strategy) edit) =>
      states.add(edit(states.last));

  step(
    (s) => withPage(s, 'page-1', (page) {
      return page.copyWith(
        agentData: [
          PlacedAgent(
            id: 'jett',
            type: AgentType.jett,
            position: const Offset(220, 140),
          ),
        ],
      );
    }),
  );
  step(
    (s) => s.copyWith(
      pages: [
        ...s.pages,
        editPage(s, 'page-1', (page) {
          return page.copyWith(
            id: 'page-2',
            name: 'Page 2',
            isAutoNamed: true,
            sortIndex: 1,
          );
        }),
      ],
    ),
  );
  step(
    (s) => withPage(s, 'page-2', (page) {
      return page.copyWith(name: 'Execute', isAutoNamed: false);
    }),
  );
  step(
    (s) => withPage(s, 'page-1', (page) {
      return page.copyWith(
        textData: [
          PlacedText(id: 'note', position: const Offset(40, 50))
            ..text = 'wait for flash',
        ],
      );
    }),
  );
  step(
    (s) => withPage(s, 'page-2', (page) {
      return page.copyWith(abilityData: const []);
    }),
  );
  step(
    (s) => s.copyWith(
      pages: [for (final page in s.pages) page.copyWith(isAttack: false)],
    ),
  );
  step(
    (s) => s.copyWith(
      pages: [
        for (final page in s.pages)
          page.copyWith(
            settings: StrategySettings(agentSize: 40, abilitySize: 30),
          ),
      ],
    ),
  );
  step(
    (s) => s.copyWith(
      pages: [
        for (final page in s.pages)
          page.copyWith(
            sortIndex: page.id == 'page-2' ? 0 : 1,
            name: page.isAutoNamed == true ? 'Page 2' : page.name,
          ),
      ],
    ),
  );
  step(
    (s) => withPage(s, 'page-1', (page) {
      return page.copyWith(
        lineUpGraph: LineUpGraph(
          origins: page.lineUpOrigins,
          landings: page.lineUpLandings,
          links: [
            for (final link in page.lineUpLinks)
              link.copyWith(notes: 'jump throw'),
          ],
        ),
      );
    }),
  );
  step(
    (s) => withPage(s, 'page-2', (page) {
      return page.copyWith(
        agentData: [
          ...page.agentData,
          PlacedAgent(
            id: 'omen',
            type: AgentType.omen,
            position: const Offset(500, 500),
          ),
        ],
      );
    }),
  );
  step(
    (s) => s.copyWith(
      pages: [
        for (final page in s.pages)
          if (page.id != 'page-1') page.copyWith(sortIndex: 0),
      ],
    ),
  );
  step(
    (s) => s.copyWith(
      name: 'Retake B fast',
      themeOverridePalette: MapThemePalette(
        baseColorValue: 0xFF101820,
        detailColorValue: 0xFF2A3440,
        highlightColorValue: 0xFFE0A030,
      ),
    ),
  );
  return states;
}

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

PlacedAbility recon(String id, double x) => reconAt(id, Offset(x, 300));

StrategyData withLastEdited(StrategyData model, int step) => model.copyWith(
      lastEdited: DateTime.utc(2026, 11, 2, 0, step),
      pages: [...model.pages]
        ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex)),
    );

StrategyPage bigPage(String id, int index, int items) => pageOf(
      id,
      index,
      agents: [
        for (var i = 0; i < items; i++)
          PlacedAgent(
            id: '$id-agent-$i',
            type: AgentType.values[i % 8],
            position: Offset(10.0 + i, 20.0 + i),
          ),
      ],
    );

Duration median(List<Duration> times) => (times..sort())[times.length ~/ 2];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => appProviderContainer = ProviderContainer());
  tearDownAll(() => appProviderContainer.dispose());

  test('every step of an editing session is stored as its image', () async {
    final states = scriptedSession();
    final storage = MemoryStorage();
    final store = await openOn(MemoryEngine(storage), states.first.mapData);
    final saves = Saves();
    for (final (index, state) in states.indexed) {
      await saves.check(
        store,
        storage,
        withLastEdited(state, index),
        'step $index',
      );
    }
    await store.close();
    expect(saves.steps, states.length);
  });

  test('every save of 30 generated sessions is stored as its image', () async {
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
    final saves = Saves();
    for (var seed = 0; seed < 30; seed++) {
      final storage = MemoryStorage();
      final store = await openOn(MemoryEngine(storage), MapValue.haven);
      final editor = Editor(seed);
      var model = start;
      await saves.check(store, storage, model, 'seed $seed start');
      for (var step = 0; step < 8; step++) {
        model = withLastEdited(editor.edit(model), step);
        await saves.check(store, storage, model, 'seed $seed step $step');
      }
      await store.close();
    }
    expect(saves.steps, 270);
    stdout.writeln(
      '${saves.steps} saves stored as their image; ${saves.lineupOrderOnly} '
      'read back with lineups that interleave across origins in group order',
    );
  });

  test('a save on SQLite: convert, compare and commit', () async {
    final folder = await Directory.systemTemp.createTemp('icarus-put-cost-');
    addTearDown(() => folder.delete(recursive: true));
    for (final (pages, items) in [(20, 25), (40, 25)]) {
      final model = strategyOf([
        for (var i = 0; i < pages; i++) bigPage('page-$i', i, items),
      ]);
      final store = await openOn(
        SqliteEngine('${folder.path}/$pages.sqlite'),
        model.mapData,
      );
      expect(await store.putStrategy(rowsOf(model)), isA<Saved>());
      final convert = <Duration>[];
      final save = <Duration>[];
      var current = model;
      for (var run = 0; run < 25; run++) {
        final page = current.pages[run % pages];
        final moved = current.copyWith(pages: [
          for (final each in current.pages)
            each.id == page.id
                ? each.copyWith(agentData: [
                    for (final (index, agent) in each.agentData.indexed)
                      index == 0
                          ? PlacedAgent(
                              id: agent.id,
                              type: (agent as PlacedAgent).type,
                              position: agent.position + const Offset(1, 0),
                            )
                          : agent,
                  ])
                : each,
        ]);
        final watch = Stopwatch()..start();
        final rows = rowsOf(moved);
        convert.add(watch.elapsed);
        expect(await store.putStrategy(rows), isA<Saved>());
        save.add(watch.elapsed);
        current = moved;
      }
      await store.close();
      stdout.writeln(
        '$pages pages, ${pages * items} items, one agent moved, SQLite: '
        'convert ${median(convert).inMicroseconds} us, convert + compare + '
        'commit ${median(save).inMicroseconds} us (medians of 25)',
      );
    }
  });
}
