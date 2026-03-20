import 'dart:io';
import 'dart:ui';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

class _NoopActionProvider extends ActionProvider {
  @override
  List<UserAction> build() => [];

  @override
  void addAction(UserAction action) {
    state = [...state, action];
  }
}

class _FixedMapProvider extends MapProvider {
  _FixedMapProvider(this.mapValue);

  final MapValue mapValue;

  @override
  MapState build() => MapState(currentMap: mapValue, isAttack: true);

  @override
  void fromHive(MapValue map, bool isAttack) {}
}

Offset _agentCenter(PlacedAgentNode agent, double agentSize) {
  return agent.position + Offset(agentSize / 2, agentSize / 2);
}

Offset _abilityScaleCenter(
  PlacedAbility ability, {
  required double mapScale,
  required double abilitySize,
}) {
  return ability.position +
      ability.data.abilityData!.getScaleCenterPoint(
        mapScale: mapScale,
        abilitySize: abilitySize,
      );
}

Offset _abilityRotatedScaleCenter(
  PlacedAbility ability, {
  required double mapScale,
  required double abilitySize,
}) {
  final scaleCenter = ability.data.abilityData!.getScaleCenterPoint(
    mapScale: mapScale,
    abilitySize: abilitySize,
  );
  final anchor = ability.data.abilityData!.getAnchorPoint(
    mapScale: mapScale,
    abilitySize: abilitySize,
  );
  final dx = scaleCenter.dx - anchor.dx;
  final dy = scaleCenter.dy - anchor.dy;
  final rotatedX =
      (dx * math.cos(ability.rotation)) - (dy * math.sin(ability.rotation));
  final rotatedY =
      (dx * math.sin(ability.rotation)) + (dy * math.cos(ability.rotation));
  return ability.position + Offset(rotatedX + anchor.dx, rotatedY + anchor.dy);
}

void _expectOffsetClose(Offset actual, Offset expected) {
  expect(actual.dx, closeTo(expected.dx, 0.0001));
  expect(actual.dy, closeTo(expected.dy, 0.0001));
}

ProviderContainer _createContainer({MapValue mapValue = MapValue.bind}) {
  final container = ProviderContainer(
    overrides: [
      actionProvider.overrideWith(_NoopActionProvider.new),
      mapProvider.overrideWith(() => _FixedMapProvider(mapValue)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const oldAgentSize = 40.0;
  const newAgentSize = 60.0;
  const oldAbilitySize = 25.0;
  const newAbilitySize = 35.0;
  const mapValue = MapValue.bind;
  final mapScale = Maps.mapScale[mapValue]!;
  var adaptersRegistered = false;

  setUp(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
    CoordinateSystem.instance.setIsScreenshot(false);
  });

  test(
    'agent reflow preserves center for plain, view-cone, and circle agents',
    () {
      final plainAgent = PlacedAgent(
        id: 'plain',
        type: AgentType.jett,
        position: const Offset(100, 200),
      );
      final viewConeAgent = PlacedViewConeAgent(
        id: 'view-cone',
        type: AgentType.sova,
        position: const Offset(150, 250),
        presetType: UtilityType.viewCone90,
        rotation: 1.2,
        length: 18,
      );
      final circleAgent = PlacedCircleAgent(
        id: 'circle',
        type: AgentType.killjoy,
        position: const Offset(220, 320),
        diameterMeters: 12,
        colorValue: 0xFF00FF00,
        opacityPercent: 80,
      );

      final cases = [plainAgent, viewConeAgent, circleAgent];

      for (final agent in cases) {
        final oldCenter = _agentCenter(agent, oldAgentSize);
        agent.reflowForAgentSizeChange(
          oldAgentSize: oldAgentSize,
          newAgentSize: newAgentSize,
        );
        final newCenter = _agentCenter(agent, newAgentSize);
        _expectOffsetClose(newCenter, oldCenter);
      }
    },
  );

  test('agent reflow translates stored undo history', () {
    final agent = PlacedAgent(
      id: 'plain-history',
      type: AgentType.jett,
      position: const Offset(10, 20),
    );
    agent.updatePosition(const Offset(30, 50));

    agent.reflowForAgentSizeChange(
      oldAgentSize: oldAgentSize,
      newAgentSize: newAgentSize,
    );
    agent.undoAction();

    _expectOffsetClose(agent.position, const Offset(0, 10));
  });

  test('ability reflow preserves visual scale center across ability types', () {
    final cases = <({String label, AbilityInfo info, bool expectZeroDelta})>[
      (
        label: 'base',
        info: AgentData.agents[AgentType.raze]!.abilities.first,
        expectZeroDelta: false,
      ),
      (
        label: 'image',
        info: AgentData.agents[AgentType.jett]!.abilities.first,
        expectZeroDelta: true,
      ),
      (
        label: 'circle',
        info: AgentData.agents[AgentType.brimstone]!.abilities[1],
        expectZeroDelta: true,
      ),
      (
        label: 'sector',
        info: AgentData.agents[AgentType.miks]!.abilities.last,
        expectZeroDelta: true,
      ),
      (
        label: 'wall-square',
        info: AgentData.agents[AgentType.viper]!.abilities[2],
        expectZeroDelta: false,
      ),
      (
        label: 'plain-square',
        info: AgentData.agents[AgentType.omen]!.abilities[1],
        expectZeroDelta: false,
      ),
      (
        label: 'resizable-square',
        info: AgentData.agents[AgentType.breach]!.abilities[2],
        expectZeroDelta: false,
      ),
      (
        label: 'center-square',
        info: AgentData.agents[AgentType.astra]!.abilities[3],
        expectZeroDelta: false,
      ),
      (
        label: 'rotatable-image',
        info: AgentData.agents[AgentType.sage]!.abilities.first,
        expectZeroDelta: true,
      ),
      (
        label: 'deadlock-mesh',
        info: AgentData.agents[AgentType.deadlock]!.abilities[2],
        expectZeroDelta: true,
      ),
    ];

    for (final testCase in cases) {
      final ability = PlacedAbility(
        id: testCase.label,
        data: testCase.info,
        position: const Offset(300, 400),
      );
      final oldCenter = _abilityScaleCenter(
        ability,
        mapScale: mapScale,
        abilitySize: oldAbilitySize,
      );

      ability.reflowForAbilitySizeChange(
        oldAbilitySize: oldAbilitySize,
        newAbilitySize: newAbilitySize,
        mapScale: mapScale,
      );

      final newCenter = _abilityScaleCenter(
        ability,
        mapScale: mapScale,
        abilitySize: newAbilitySize,
      );

      _expectOffsetClose(newCenter, oldCenter);
      if (testCase.expectZeroDelta) {
        _expectOffsetClose(ability.position, const Offset(300, 400));
      }
    }
  });

  test(
    'cypher, neon, and astra special cases preserve the intended scale center',
    () {
      final cases = <AbilityInfo>[
        AgentData.agents[AgentType.cypher]!.abilities.first,
        AgentData.agents[AgentType.neon]!.abilities.first,
        AgentData.agents[AgentType.astra]!.abilities[3],
      ];

      for (final info in cases) {
        final ability = PlacedAbility(
          id: info.name,
          data: info,
          position: const Offset(180, 240),
        );
        final oldCenter = _abilityScaleCenter(
          ability,
          mapScale: mapScale,
          abilitySize: oldAbilitySize,
        );

        ability.reflowForAbilitySizeChange(
          oldAbilitySize: oldAbilitySize,
          newAbilitySize: newAbilitySize,
          mapScale: mapScale,
        );

        final newCenter = _abilityScaleCenter(
          ability,
          mapScale: mapScale,
          abilitySize: newAbilitySize,
        );
        _expectOffsetClose(newCenter, oldCenter);
      }
    },
  );

  test(
    'rotated cypher and neon walls preserve their rotated visual scale center',
    () {
      final cases = <AbilityInfo>[
        AgentData.agents[AgentType.cypher]!.abilities.first,
        AgentData.agents[AgentType.neon]!.abilities.first,
      ];

      for (final info in cases) {
        final ability = PlacedAbility(
          id: '${info.name}-rotated',
          data: info,
          position: const Offset(210, 280),
          rotation: math.pi / 3,
        );
        final oldCenter = _abilityRotatedScaleCenter(
          ability,
          mapScale: mapScale,
          abilitySize: oldAbilitySize,
        );

        ability.reflowForAbilitySizeChange(
          oldAbilitySize: oldAbilitySize,
          newAbilitySize: newAbilitySize,
          mapScale: mapScale,
        );

        final newCenter = _abilityRotatedScaleCenter(
          ability,
          mapScale: mapScale,
          abilitySize: newAbilitySize,
        );
        _expectOffsetClose(newCenter, oldCenter);
      }
    },
  );

  test('ability reflow translates stored undo history', () {
    final ability = PlacedAbility(
      id: 'base-history',
      data: AgentData.agents[AgentType.raze]!.abilities.first,
      position: const Offset(40, 60),
    );
    ability.updatePosition(const Offset(100, 120));

    ability.reflowForAbilitySizeChange(
      oldAbilitySize: oldAbilitySize,
      newAbilitySize: newAbilitySize,
      mapScale: mapScale,
    );
    ability.undoAction();

    _expectOffsetClose(ability.position, const Offset(35, 55));
  });

  test('strategy settings reflow live providers and deleted items', () {
    final container = _createContainer();
    final settingsNotifier = container.read(strategySettingsProvider.notifier);
    settingsNotifier.fromHive(
      StrategySettings(agentSize: oldAgentSize, abilitySize: oldAbilitySize),
    );

    final livePlainAgent = PlacedAgent(
      id: 'live-plain',
      type: AgentType.jett,
      position: const Offset(100, 100),
    );
    final liveViewConeAgent = PlacedViewConeAgent(
      id: 'live-cone',
      type: AgentType.sova,
      position: const Offset(140, 180),
      presetType: UtilityType.viewCone90,
      rotation: 0.7,
      length: 24,
    );
    final deletedCircleAgent = PlacedCircleAgent(
      id: 'deleted-circle',
      type: AgentType.killjoy,
      position: const Offset(220, 260),
      diameterMeters: 10,
      colorValue: 0xFFFFFFFF,
      opacityPercent: 100,
    );

    final agentNotifier = container.read(agentProvider.notifier);
    agentNotifier.fromHive([
      livePlainAgent,
      liveViewConeAgent,
      deletedCircleAgent,
    ]);
    agentNotifier.removeAgent(deletedCircleAgent.id);

    final liveBaseAbility = PlacedAbility(
      id: 'live-base',
      data: AgentData.agents[AgentType.raze]!.abilities.first,
      position: const Offset(300, 340),
    );
    final deletedBaseAbility = PlacedAbility(
      id: 'deleted-base',
      data: AgentData.agents[AgentType.astra]!.abilities.last,
      position: const Offset(360, 420),
    );
    final abilityNotifier = container.read(abilityProvider.notifier);
    abilityNotifier.fromHive([liveBaseAbility, deletedBaseAbility]);
    abilityNotifier.removeAbility(deletedBaseAbility.id);

    final lineUpNotifier = container.read(lineUpProvider.notifier);
    final currentLineupAgent = PlacedAgent(
      id: 'lineup-agent',
      type: AgentType.astra,
      position: const Offset(420, 480),
    );
    final currentLineupAbility = PlacedAbility(
      id: 'lineup-ability',
      data: AgentData.agents[AgentType.astra]!.abilities[3],
      position: const Offset(520, 580),
    );
    lineUpNotifier.setAgent(currentLineupAgent);
    lineUpNotifier.setAbility(currentLineupAbility);

    final oldPlainCenter = _agentCenter(livePlainAgent, oldAgentSize);
    final oldViewConeCenter = _agentCenter(liveViewConeAgent, oldAgentSize);
    final oldDeletedCircleCenter = _agentCenter(
      deletedCircleAgent,
      oldAgentSize,
    );
    final oldLiveBaseCenter = _abilityScaleCenter(
      liveBaseAbility,
      mapScale: mapScale,
      abilitySize: oldAbilitySize,
    );
    final oldDeletedBaseCenter = _abilityScaleCenter(
      deletedBaseAbility,
      mapScale: mapScale,
      abilitySize: oldAbilitySize,
    );
    final oldLineupAgentCenter = _agentCenter(currentLineupAgent, oldAgentSize);
    final oldLineupAbilityCenter = _abilityScaleCenter(
      currentLineupAbility,
      mapScale: mapScale,
      abilitySize: oldAbilitySize,
    );

    settingsNotifier.updateAgentSize(newAgentSize);
    settingsNotifier.updateAbilitySize(newAbilitySize);

    final agents = container.read(agentProvider);
    _expectOffsetClose(
      _agentCenter(
        agents.firstWhere((agent) => agent.id == livePlainAgent.id),
        newAgentSize,
      ),
      oldPlainCenter,
    );
    _expectOffsetClose(
      _agentCenter(
        agents.firstWhere((agent) => agent.id == liveViewConeAgent.id),
        newAgentSize,
      ),
      oldViewConeCenter,
    );

    agentNotifier.undoAction(
      UserAction(
        type: ActionType.deletion,
        id: deletedCircleAgent.id,
        group: ActionGroup.agent,
      ),
    );
    final restoredDeletedAgent = container
        .read(agentProvider)
        .firstWhere((agent) => agent.id == deletedCircleAgent.id);
    _expectOffsetClose(
      _agentCenter(restoredDeletedAgent, newAgentSize),
      oldDeletedCircleCenter,
    );

    final abilities = container.read(abilityProvider);
    _expectOffsetClose(
      _abilityScaleCenter(
        abilities.firstWhere((ability) => ability.id == liveBaseAbility.id),
        mapScale: mapScale,
        abilitySize: newAbilitySize,
      ),
      oldLiveBaseCenter,
    );

    abilityNotifier.undoAction(
      UserAction(
        type: ActionType.deletion,
        id: deletedBaseAbility.id,
        group: ActionGroup.ability,
      ),
    );
    final restoredDeletedAbility = container
        .read(abilityProvider)
        .firstWhere((ability) => ability.id == deletedBaseAbility.id);
    _expectOffsetClose(
      _abilityScaleCenter(
        restoredDeletedAbility,
        mapScale: mapScale,
        abilitySize: newAbilitySize,
      ),
      oldDeletedBaseCenter,
    );

    final lineUpState = container.read(lineUpProvider);
    _expectOffsetClose(
      _agentCenter(lineUpState.currentAgent!, newAgentSize),
      oldLineupAgentCenter,
    );
    _expectOffsetClose(
      _abilityScaleCenter(
        lineUpState.currentAbility!,
        mapScale: mapScale,
        abilitySize: newAbilitySize,
      ),
      oldLineupAbilityCenter,
    );
  });

  test(
    'applyMarkerSizesToAllPages reflows inactive pages and lineups',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'icarus-marker-size-',
      );
      Hive.init(tempDir.path);
      if (!adaptersRegistered) {
        registerIcarusAdapters(Hive);
        adaptersRegistered = true;
      }
      final box = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
      addTearDown(() async {
        await Hive.close();
        await tempDir.delete(recursive: true);
      });

      const inactiveAgentPosition = Offset(100, 140);
      const inactiveAbilityPosition = Offset(200, 260);
      const inactiveLineupAgentPosition = Offset(300, 360);
      const inactiveLineupAbilityPosition = Offset(420, 500);

      final inactiveAgent = PlacedAgent(
        id: 'inactive-agent',
        type: AgentType.jett,
        position: inactiveAgentPosition,
      );
      final inactiveAbility = PlacedAbility(
        id: 'inactive-ability',
        data: AgentData.agents[AgentType.astra]!.abilities.last,
        position: inactiveAbilityPosition,
      );
      final inactiveLineup = LineUp(
        id: 'inactive-lineup',
        agent: PlacedAgent(
          id: 'inactive-lineup-agent',
          type: AgentType.astra,
          position: inactiveLineupAgentPosition,
        ),
        ability: PlacedAbility(
          id: 'inactive-lineup-ability',
          data: AgentData.agents[AgentType.astra]!.abilities[3],
          position: inactiveLineupAbilityPosition,
        ),
        youtubeLink: '',
        images: const [],
        notes: '',
      );

      final pageOne = StrategyPage(
        id: 'page-1',
        name: 'Page 1',
        drawingData: const [],
        agentData: const [],
        abilityData: const [],
        textData: const [],
        imageData: const [],
        utilityData: const [],
        sortIndex: 0,
        isAttack: true,
        settings: StrategySettings(
          agentSize: oldAgentSize,
          abilitySize: oldAbilitySize,
        ),
      );
      final pageTwo = StrategyPage(
        id: 'page-2',
        name: 'Page 2',
        drawingData: const [],
        agentData: [inactiveAgent],
        abilityData: [inactiveAbility],
        textData: const [],
        imageData: const [],
        utilityData: const [],
        sortIndex: 1,
        isAttack: true,
        settings: StrategySettings(
          agentSize: oldAgentSize,
          abilitySize: oldAbilitySize,
        ),
        lineUps: [inactiveLineup],
      );
      final strategy = StrategyData(
        id: 'strategy-1',
        name: 'Strategy 1',
        mapData: mapValue,
        versionNumber: 1,
        lastEdited: DateTime(2024),
        folderID: null,
        pages: [pageOne, pageTwo],
      );
      await box.put(strategy.id, strategy);

      final container = _createContainer();
      final strategyNotifier = container.read(strategyProvider.notifier);
      strategyNotifier
        ..setFromState(
          StrategyState(
            isSaved: false,
            stratName: strategy.name,
            id: strategy.id,
            storageDirectory: null,
            activePageId: pageOne.id,
          ),
        )
        ..activePageID = pageOne.id;

      container
          .read(strategySettingsProvider.notifier)
          .fromHive(pageOne.settings);
      container
          .read(mapProvider.notifier)
          .fromHive(strategy.mapData, pageOne.isAttack);
      container.read(agentProvider.notifier).fromHive(pageOne.agentData);
      container.read(abilityProvider.notifier).fromHive(pageOne.abilityData);
      container.read(lineUpProvider.notifier).fromHive(pageOne.lineUps);

      final oldInactiveAgentCenter = _agentCenter(inactiveAgent, oldAgentSize);
      final oldInactiveAbilityCenter = _abilityScaleCenter(
        inactiveAbility,
        mapScale: mapScale,
        abilitySize: oldAbilitySize,
      );
      final oldInactiveLineupAgentCenter = _agentCenter(
        inactiveLineup.agent,
        oldAgentSize,
      );
      final oldInactiveLineupAbilityCenter = _abilityScaleCenter(
        inactiveLineup.ability,
        mapScale: mapScale,
        abilitySize: oldAbilitySize,
      );

      final settingsNotifier = container.read(
        strategySettingsProvider.notifier,
      );
      settingsNotifier.updateAgentSize(newAgentSize);
      settingsNotifier.updateAbilitySize(newAbilitySize);

      await strategyNotifier.applyMarkerSizesToAllPages();
      await strategyNotifier.forceSaveNow(strategy.id);

      final saved = box.get(strategy.id)!;
      final savedInactivePage = saved.pages.firstWhere(
        (page) => page.id == pageTwo.id,
      );
      final savedInactiveAgent = savedInactivePage.agentData.single;
      final savedInactiveAbility = savedInactivePage.abilityData.single;
      final savedInactiveLineup = savedInactivePage.lineUps.single;

      expect(savedInactivePage.settings.agentSize, newAgentSize);
      expect(savedInactivePage.settings.abilitySize, newAbilitySize);
      _expectOffsetClose(
        _agentCenter(savedInactiveAgent, newAgentSize),
        oldInactiveAgentCenter,
      );
      _expectOffsetClose(
        _abilityScaleCenter(
          savedInactiveAbility,
          mapScale: mapScale,
          abilitySize: newAbilitySize,
        ),
        oldInactiveAbilityCenter,
      );
      _expectOffsetClose(
        _agentCenter(savedInactiveLineup.agent, newAgentSize),
        oldInactiveLineupAgentCenter,
      );
      _expectOffsetClose(
        _abilityScaleCenter(
          savedInactiveLineup.ability,
          mapScale: mapScale,
          abilitySize: newAbilitySize,
        ),
        oldInactiveLineupAbilityCenter,
      );
    },
  );
}
