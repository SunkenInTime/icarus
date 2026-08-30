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
    ]).copyWith(versionNumber: Settings.versionNumber - 1);

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
        isTrue,
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
        isFalse,
      );
      expect(
        await notifier.copyPlacedWidgetToAdjacentPage(
          widgetId: sourceAgent.id,
          direction: PageTransitionDirection.forward,
        ),
        isFalse,
      );

      final savedTarget = strategyBox
          .get(strategy.id)!
          .pages
          .singleWhere((page) => page.id == 'page-2');
      expect(savedTarget.agentData, hasLength(1));
      expect(savedTarget.agentData.single.position, const Offset(300, 400));
    },
  );
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
  container.read(lineUpProvider.notifier).fromHive(page.lineUpGroups);
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
