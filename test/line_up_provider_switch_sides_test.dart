import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/map_provider.dart';
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
  _FixedMapProvider({
    required this.mapValue,
  });

  final MapValue mapValue;

  @override
  MapState build() => MapState(currentMap: mapValue, isAttack: true);

  @override
  void fromHive(MapValue map, bool isAttack) {}
}

ProviderContainer _createContainer(MapValue mapValue) {
  final container = ProviderContainer(
    overrides: [
      actionProvider.overrideWith(_NoopActionProvider.new),
      mapProvider.overrideWith(() => _FixedMapProvider(mapValue: mapValue)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LineUpProvider.switchSides', () {
    late AbilityInfo abilityInfo;

    setUp(() {
      CoordinateSystem(playAreaSize: const Size(1920, 1080));
      abilityInfo = AgentData.agents[AgentType.deadlock]!.abilities[2];
    });

    test('deleted lineup is flipped while stored in popped lineups', () {
      final container = _createContainer(MapValue.bind);
      final notifier = container.read(lineUpProvider.notifier);
      final agentSize = container.read(strategySettingsProvider).agentSize;
      final abilitySize = container.read(strategySettingsProvider).abilitySize;
      final mapScale = Maps.mapScale[MapValue.bind]!;

      const initialAgentPosition = Offset(100.0, 200.0);
      const initialAbilityPosition = Offset(300.0, 400.0);
      const initialAbilityRotation = math.pi / 4;

      final lineUp = LineUp(
        id: 'lineup-1',
        agent: PlacedAgent(
          id: 'lineup-agent-1',
          type: AgentType.deadlock,
          position: initialAgentPosition,
        ),
        ability: PlacedAbility(
          id: 'lineup-ability-1',
          data: abilityInfo,
          position: initialAbilityPosition,
          rotation: initialAbilityRotation,
        ),
        youtubeLink: '',
        images: const [],
        notes: '',
      );

      notifier.fromHive([lineUp]);
      notifier.deleteLineUpById(lineUp.id);
      notifier.switchSides();
      notifier.undoAction(
        UserAction(
          type: ActionType.deletion,
          id: lineUp.id,
          group: ActionGroup.lineUp,
        ),
      );

      final restoredLineUp = container.read(lineUpProvider).lineUps.single;
      final expectedAgentPosition = getFlippedPosition(
        position: initialAgentPosition,
        scaledSize: Offset(
          CoordinateSystem.instance.scale(agentSize),
          CoordinateSystem.instance.scale(agentSize),
        ),
      );
      final abilitySizePx = abilityInfo.abilityData!
          .getSize(mapScale: mapScale, abilitySize: abilitySize)
          .scale(
            CoordinateSystem.instance.scaleFactor,
            CoordinateSystem.instance.scaleFactor,
          );
      final expectedAbilityPosition = getFlippedPosition(
        position: initialAbilityPosition,
        scaledSize: abilitySizePx,
      );

      expect(
        restoredLineUp.agent.position.dx,
        closeTo(expectedAgentPosition.dx, 0.0001),
      );
      expect(
        restoredLineUp.agent.position.dy,
        closeTo(expectedAgentPosition.dy, 0.0001),
      );
      expect(
        restoredLineUp.ability.position.dx,
        closeTo(expectedAbilityPosition.dx, 0.0001),
      );
      expect(
        restoredLineUp.ability.position.dy,
        closeTo(expectedAbilityPosition.dy, 0.0001),
      );
      expect(
        restoredLineUp.ability.rotation,
        closeTo(initialAbilityRotation + math.pi, 0.0001),
      );
    });

    test('current lineup placement flips on side switch', () {
      final container = _createContainer(MapValue.bind);
      final notifier = container.read(lineUpProvider.notifier);
      final agentSize = container.read(strategySettingsProvider).agentSize;
      final abilitySize = container.read(strategySettingsProvider).abilitySize;
      final mapScale = Maps.mapScale[MapValue.bind]!;

      const initialAgentPosition = Offset(120.0, 220.0);
      const initialAbilityPosition = Offset(320.0, 420.0);
      const initialAbilityRotation = math.pi / 6;

      notifier.setAgent(
        PlacedAgent(
          id: 'current-agent',
          type: AgentType.deadlock,
          position: initialAgentPosition,
        ),
      );
      notifier.setAbility(
        PlacedAbility(
          id: 'current-ability',
          data: abilityInfo,
          position: initialAbilityPosition,
          rotation: initialAbilityRotation,
        ),
      );

      notifier.switchSides();

      final currentState = container.read(lineUpProvider);
      final currentAgent = currentState.currentAgent;
      final currentAbility = currentState.currentAbility;
      expect(currentAgent, isNotNull);
      expect(currentAbility, isNotNull);

      final expectedAgentPosition = getFlippedPosition(
        position: initialAgentPosition,
        scaledSize: Offset(
          CoordinateSystem.instance.scale(agentSize),
          CoordinateSystem.instance.scale(agentSize),
        ),
      );
      final abilitySizePx = abilityInfo.abilityData!
          .getSize(mapScale: mapScale, abilitySize: abilitySize)
          .scale(
            CoordinateSystem.instance.scaleFactor,
            CoordinateSystem.instance.scaleFactor,
          );
      final expectedAbilityPosition = getFlippedPosition(
        position: initialAbilityPosition,
        scaledSize: abilitySizePx,
      );

      expect(
        currentAgent!.position.dx,
        closeTo(expectedAgentPosition.dx, 0.0001),
      );
      expect(
        currentAgent.position.dy,
        closeTo(expectedAgentPosition.dy, 0.0001),
      );
      expect(
        currentAbility!.position.dx,
        closeTo(expectedAbilityPosition.dx, 0.0001),
      );
      expect(
        currentAbility.position.dy,
        closeTo(expectedAbilityPosition.dy, 0.0001),
      );
      expect(
        currentAbility.rotation,
        closeTo(initialAbilityRotation + math.pi, 0.0001),
      );
    });
  });
}
