import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/migrations/page_name_provenance_migration.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/utility_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  CoordinateSystem(playAreaSize: const Size(1920, 1080));

  late Directory tempDir;
  late Box<StrategyData> strategyBox;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('icarus-page-semantics-');
    Hive.init(tempDir.path);
    if (!Hive.isAdapterRegistered(9)) {
      registerIcarusAdapters(Hive);
    }
    strategyBox = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
  });

  tearDown(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  test('addPage duplicates and renumbers immediately after the active page',
      () async {
    final sourceAgent = PlacedAgent(
      id: 'agent-on-page-2',
      type: AgentType.jett,
      position: const Offset(120, 240),
    );
    final pages = [
      _page(
        id: 'page-1',
        name: 'Page 1',
        sortIndex: 0,
        agents: [sourceAgent],
      ),
      _page(id: 'page-2', name: 'Page 2', sortIndex: 1),
      _page(id: 'page-3', name: 'Page 3', sortIndex: 2),
    ];
    final strategy = _strategy(pages);
    await strategyBox.put(strategy.id, strategy);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    _activatePage(container, strategy, pages[0]);

    await container.read(strategyProvider.notifier).addPage();

    final saved = strategyBox.get(strategy.id)!;
    final ordered = [...saved.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));

    expect(ordered.map((page) => page.id), [
      'page-1',
      isNot(anyOf('page-1', 'page-2', 'page-3')),
      'page-2',
      'page-3',
    ]);
    expect(ordered.map((page) => page.sortIndex), [0, 1, 2, 3]);
    expect(ordered.map((page) => page.name), [
      'Page 1',
      'Page 2',
      'Page 3',
      'Page 4',
    ]);
    expect(ordered[1].agentData.single.id, sourceAgent.id);
    expect(container.read(strategyProvider).activePageId, ordered[1].id);
  });

  test('reorder renumbers default names and preserves custom names', () async {
    final pages = [
      _page(id: 'page-1', name: 'Page 1', sortIndex: 0),
      _page(id: 'page-2', name: 'Site Execute', sortIndex: 1),
      _page(id: 'page-3', name: 'Page 3', sortIndex: 2),
    ];
    final strategy = _strategy(pages);
    await strategyBox.put(strategy.id, strategy);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    _activatePage(container, strategy, pages.first);

    await container.read(strategyProvider.notifier).reorderPage(2, 0);

    final ordered = [...strategyBox.get(strategy.id)!.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    expect(ordered.map((page) => page.id), ['page-3', 'page-1', 'page-2']);
    expect(ordered.map((page) => page.name), [
      'Page 1',
      'Page 2',
      'Site Execute',
    ]);
  });

  test('a custom name matching Page N is never automatically renumbered', () {
    final pages = [
      _page(id: 'page-1', name: 'Page 1', sortIndex: 0),
      _page(
        id: 'custom-page-2',
        name: 'Page 2',
        sortIndex: 1,
        isAutoNamed: false,
      ),
      _page(id: 'page-3', name: 'Page 3', sortIndex: 2),
    ];

    final reindexed = StrategyProvider.reindexPagesAfterStructuralChange([
      pages[1],
      pages[0],
      pages[2],
    ]);

    expect(reindexed.map((page) => page.name), [
      'Page 2',
      'Page 2',
      'Page 3',
    ]);
    expect(reindexed.first.isAutoNamed, isFalse);
    expect(reindexed[1].isAutoNamed, isTrue);
  });

  test('page-name migration leaves historical provenance unresolved', () {
    final oldStrategy = _strategy([
      _page(
        id: 'page-1',
        name: 'Page 1',
        sortIndex: 0,
        hasNameProvenance: false,
      ),
      _page(
        id: 'custom-page',
        name: 'Site Execute',
        sortIndex: 1,
        hasNameProvenance: false,
      ),
      _page(
        id: 'explicit-custom-page',
        name: 'Page 3',
        sortIndex: 2,
        isAutoNamed: false,
      ),
    ]).copyWith(versionNumber: PageNameProvenanceMigration.version - 1);

    final migrated = StrategyProvider.migrateToCurrentVersion(oldStrategy);

    expect(migrated.versionNumber, Settings.versionNumber);
    expect(migrated.pages[0].isAutoNamed, isNull);
    expect(migrated.pages[1].isAutoNamed, isNull);
    expect(migrated.pages[2].isAutoNamed, isFalse);
  });

  test('delete renumbering closes gaps without changing custom names', () {
    final pages = [
      _page(id: 'page-1', name: 'Page 1', sortIndex: 0),
      _page(id: 'page-2', name: 'Site Execute', sortIndex: 1),
      _page(id: 'page-3', name: 'Page 3', sortIndex: 2),
    ];

    final reindexed = StrategyProvider.reindexPagesAfterStructuralChange([
      pages[1],
      pages[2],
    ]);

    expect(reindexed.map((page) => page.name), ['Site Execute', 'Page 2']);
    expect(reindexed.map((page) => page.sortIndex), [0, 1]);
  });

  test('placed widgets copy to the next page with their IDs intact', () async {
    final agent = PlacedAgent(
      id: 'agent-id',
      type: AgentType.jett,
      position: const Offset(10, 20),
    );
    final ability = PlacedAbility(
      id: 'ability-id',
      data: AgentData.agents[AgentType.jett]!.abilities.first,
      position: const Offset(30, 40),
    );
    final text = PlacedText(id: 'text-id', position: const Offset(50, 60))
      ..text = 'Rotate A';
    final image = PlacedImage(
      id: 'image-id',
      position: const Offset(70, 80),
      aspectRatio: 1.5,
      scale: 220,
      fileExtension: '.png',
      sizeVersion: worldSizedMediaVersion,
    )..link = 'strategy/images/image-id.png';
    final utility = PlacedUtility(
      id: 'utility-id',
      type: UtilityType.spike,
      position: const Offset(90, 100),
    );
    final pages = [
      _page(id: 'page-1', name: 'Page 1', sortIndex: 0),
      _page(
        id: 'page-2',
        name: 'Page 2',
        sortIndex: 1,
        agents: [agent],
        abilities: [ability],
        text: [text],
        images: [image],
        utilities: [utility],
      ),
      _page(id: 'page-3', name: 'Page 3', sortIndex: 2),
    ];
    final strategy = _strategy(pages);
    await strategyBox.put(strategy.id, strategy);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    _activatePage(container, strategy, pages[1]);
    final notifier = container.read(strategyProvider.notifier);

    for (final id in [agent.id, ability.id, text.id, image.id, utility.id]) {
      expect(
        await notifier.copyPlacedWidgetToAdjacentPage(
          widgetId: id,
          direction: PageTransitionDirection.forward,
        ),
        PageCopyResult.copied,
      );
    }

    final target = strategyBox
        .get(strategy.id)!
        .pages
        .singleWhere((page) => page.id == 'page-3');
    expect(target.agentData.single.id, agent.id);
    expect(target.abilityData.single.id, ability.id);
    expect(target.textData.single.id, text.id);
    expect(target.imageData.single.id, image.id);
    expect(target.utilityData.single.id, utility.id);
    expect(container.read(strategyProvider).activePageId, 'page-2');
    expect(notifier.copyDirectionsForPlacedWidget(agent.id), [
      PageTransitionDirection.backward,
    ]);
  });

  test(
    'copying is linear and never overwrites an existing transition ID',
    () async {
      final sourceAgent = PlacedAgent(
        id: 'shared-agent',
        type: AgentType.jett,
        position: const Offset(10, 20),
      );
      final existingTargetAgent = sourceAgent.copyWith(
        position: const Offset(300, 400),
      );
      final pages = [
        _page(
          id: 'page-1',
          name: 'Page 1',
          sortIndex: 0,
          agents: [sourceAgent],
        ),
        _page(
          id: 'page-2',
          name: 'Page 2',
          sortIndex: 1,
          agents: [existingTargetAgent],
        ),
      ];
      final strategy = _strategy(pages);
      await strategyBox.put(strategy.id, strategy);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      _activatePage(container, strategy, pages.first);
      final notifier = container.read(strategyProvider.notifier);

      expect(notifier.copyDirectionsForPlacedWidget(sourceAgent.id), isEmpty);
      expect(
        await notifier.copyPlacedWidgetToAdjacentPage(
          widgetId: sourceAgent.id,
          direction: PageTransitionDirection.backward,
        ),
        PageCopyResult.unavailable,
      );
      expect(
        await notifier.copyPlacedWidgetToAdjacentPage(
          widgetId: sourceAgent.id,
          direction: PageTransitionDirection.forward,
        ),
        PageCopyResult.alreadyThere,
      );

      final savedTarget = strategyBox
          .get(strategy.id)!
          .pages
          .singleWhere((page) => page.id == 'page-2');
      expect(savedTarget.agentData, hasLength(1));
      expect(savedTarget.agentData.single.position, const Offset(300, 400));
    },
  );

  group('moving and copying lineups to another page', () {
    // Sova stands at two spots. Two lineups from them meet at one landing;
    // a third goes from the first spot to another landing.
    LineUpGraph sovaLineUps() {
      final ability = AgentData.agents[AgentType.sova]!.abilities.first;
      LineUpOrigin origin(String id, Offset at) => LineUpOrigin(
            id: id,
            agent: PlacedAgent(
              id: 'agent-$id',
              type: AgentType.sova,
              position: at,
              lineUpID: id,
            ),
          );
      LineUpLanding landing(String id, Offset at) => LineUpLanding(
            id: id,
            ability: PlacedAbility(
              id: 'ability-$id',
              data: ability,
              position: at,
              lineUpID: id,
            ),
          );
      return LineUpGraph(
        origins: [
          origin('stand-1', const Offset(10, 10)),
          origin('stand-2', const Offset(20, 10)),
        ],
        landings: [
          landing('land-1', const Offset(300, 300)),
          landing('land-2', const Offset(400, 300)),
        ],
        links: [
          LineUpLink(
            id: 'bolt-a',
            originId: 'stand-1',
            landingId: 'land-1',
            name: 'Bolt A',
            notes: 'Jump throw',
            images: [SimpleImageData(id: 'shot-a', fileExtension: '.png')],
          ),
          LineUpLink(
            id: 'bolt-b',
            originId: 'stand-2',
            landingId: 'land-1',
            name: 'Bolt B',
          ),
          LineUpLink(
            id: 'recon',
            originId: 'stand-1',
            landingId: 'land-2',
            name: 'Recon',
          ),
        ],
      );
    }

    Future<ProviderContainer> open({
      LineUpGraph targetLineUps = LineUpGraph.empty,
    }) async {
      final pages = [
        _page(id: 'page-1', name: 'Page 1', sortIndex: 0),
        _page(
          id: 'page-2',
          name: 'Page 2',
          sortIndex: 1,
          lineUps: sovaLineUps(),
        ),
        _page(id: 'page-3', name: 'Page 3', sortIndex: 2),
        _page(
          id: 'page-4',
          name: 'Retake',
          sortIndex: 3,
          lineUps: targetLineUps,
        ),
      ];
      final strategy = _strategy(pages);
      await strategyBox.put(strategy.id, strategy);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      _activatePage(container, strategy, pages[1]);
      return container;
    }

    LineUpGraph savedLineUps(String pageId) => strategyBox
        .get('strategy-id')!
        .pages
        .singleWhere((page) => page.id == pageId)
        .lineUpGraph;

    test('every other page is offered, in order', () async {
      final container = await open();
      expect(
        container.read(strategyProvider.notifier).lineUpPageTargets(),
        [
          (id: 'page-1', name: 'Page 1', offset: -1),
          (id: 'page-3', name: 'Page 3', offset: 1),
          (id: 'page-4', name: 'Retake', offset: 2),
        ],
      );
    });

    test(
        'a move puts the lineups on the page under new ids and leaves a '
        'spot another lineup here still uses', () async {
      final container = await open();

      expect(
        await container.read(strategyProvider.notifier).sendLineUpsToPage(
          linkIds: {'bolt-a', 'bolt-b'},
          pageId: 'page-4',
          move: true,
        ),
        LineUpPageResult.done,
      );

      // This page keeps Recon and the spot it stands at.
      final here = container.read(lineUpProvider);
      expect(here.links.map((link) => link.id), ['recon']);
      expect(here.origins.map((origin) => origin.id), ['stand-1']);
      expect(here.landings.map((landing) => landing.id), ['land-2']);

      // The other page has both lineups, still meeting at one landing, with
      // their names, notes and screenshots, where they were.
      final there = savedLineUps('page-4');
      expect(there.links.map((link) => link.name), ['Bolt A', 'Bolt B']);
      expect(there.origins, hasLength(2));
      expect(there.landings, hasLength(1));
      final ids = {
        for (final origin in there.origins) origin.id,
        for (final landing in there.landings) landing.id,
        for (final link in there.links) link.id,
      };
      expect(ids, hasLength(5));
      expect(
        ids.intersection(
          {'stand-1', 'stand-2', 'land-1', 'land-2', 'bolt-a', 'bolt-b'},
        ),
        isEmpty,
      );
      expect(
        there.links.map((link) => link.landingId).toSet(),
        {there.landings.single.id},
      );
      expect(
        there.links.map((link) => link.originId).toSet(),
        {for (final origin in there.origins) origin.id},
      );
      for (final origin in there.origins) {
        expect(origin.agent.lineUpID, origin.id);
      }
      expect(there.landings.single.ability.lineUpID, there.landings.single.id);
      expect(there.landings.single.ability.position, const Offset(300, 300));
      final boltA = there.links.first;
      expect(boltA.notes, 'Jump throw');
      expect(boltA.images.single.id, 'shot-a');
      expect(
        there.origins
            .singleWhere((origin) => origin.id == boltA.originId)
            .agent
            .position,
        const Offset(10, 10),
      );
    });

    test('undo after a move brings the lineups back to this page', () async {
      final container = await open();
      await container.read(strategyProvider.notifier).sendLineUpsToPage(
        linkIds: {'bolt-a', 'bolt-b'},
        pageId: 'page-4',
        move: true,
      );

      container.read(actionProvider.notifier).undoAction();

      expect(
        container.read(lineUpProvider).links.map((link) => link.id).toSet(),
        {'bolt-a', 'bolt-b', 'recon'},
      );
    });

    test('a copy leaves this page as it was and adds to what is there',
        () async {
      final container = await open(targetLineUps: sovaLineUps());

      expect(
        await container.read(strategyProvider.notifier).sendLineUpsToPage(
          linkIds: {'recon'},
          pageId: 'page-4',
          move: false,
        ),
        LineUpPageResult.done,
      );

      expect(container.read(lineUpProvider).links, hasLength(3));
      final there = savedLineUps('page-4');
      expect(there.links.map((link) => link.name),
          ['Bolt A', 'Bolt B', 'Recon', 'Recon']);
      final copy = there.links.last;
      expect(copy.id, isNot('recon'));
      expect(
        there.origins
            .singleWhere((origin) => origin.id == copy.originId)
            .agent
            .position,
        const Offset(10, 10),
      );
      expect(
        there.landings
            .singleWhere((landing) => landing.id == copy.landingId)
            .ability
            .position,
        const Offset(400, 300),
      );
    });
  });
}

StrategyData _strategy(List<StrategyPage> pages) {
  return StrategyData(
    id: 'strategy-id',
    name: 'Strategy',
    mapData: MapValue.ascent,
    versionNumber: Settings.versionNumber,
    lastEdited: DateTime.utc(2026, 1, 1),
    folderID: null,
    pages: pages,
  );
}

StrategyPage _page({
  required String id,
  required String name,
  required int sortIndex,
  bool? isAutoNamed,
  bool hasNameProvenance = true,
  List<PlacedAgentNode> agents = const [],
  List<PlacedAbility> abilities = const [],
  List<PlacedText> text = const [],
  List<PlacedImage> images = const [],
  List<PlacedUtility> utilities = const [],
  LineUpGraph lineUps = LineUpGraph.empty,
}) {
  return StrategyPage(
    id: id,
    name: name,
    isAutoNamed: hasNameProvenance
        ? isAutoNamed ?? name == 'Page ${sortIndex + 1}'
        : null,
    sortIndex: sortIndex,
    drawingData: const [],
    agentData: agents,
    abilityData: abilities,
    textData: text,
    imageData: images,
    utilityData: utilities,
    lineUpOrigins: lineUps.origins,
    lineUpLandings: lineUps.landings,
    lineUpLinks: lineUps.links,
    isAttack: true,
    settings: StrategySettings(),
  );
}

void _activatePage(
  ProviderContainer container,
  StrategyData strategy,
  StrategyPage page,
) {
  container.read(agentProvider.notifier).fromHive(page.agentData);
  container.read(abilityProvider.notifier).fromHive(page.abilityData);
  container.read(drawingProvider.notifier).fromHive(page.drawingData);
  container.read(textProvider.notifier).fromHive(page.textData);
  container.read(placedImageProvider.notifier).fromHive(page.imageData);
  container.read(utilityProvider.notifier).fromHive(page.utilityData);
  container.read(lineUpProvider.notifier).fromHive(page.lineUpGraph);
  container
      .read(mapProvider.notifier)
      .fromHive(strategy.mapData, page.isAttack);
  container.read(strategySettingsProvider.notifier).fromHive(page.settings);

  container.read(strategyProvider.notifier)
    ..setFromState(
      StrategyState(
        isSaved: true,
        stratName: strategy.name,
        id: strategy.id,
        storageDirectory: null,
        activePageId: page.id,
      ),
    )
    ..activePageID = page.id;
}
