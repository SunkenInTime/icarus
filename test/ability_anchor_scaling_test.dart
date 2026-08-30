import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

class _NoopStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() {
    return StrategyState(
      isSaved: true,
      stratName: 'anchor-test',
      id: 'anchor-test',
      storageDirectory: null,
      activePageId: null,
    );
  }

  @override
  void setUnsaved() {
    state = state.copyWith(isSaved: false);
  }
}

Iterable<AbilityInfo> _representativeAbilityInfos() sync* {
  final seenTypes = <Type>{};
  for (final agent in AgentData.agents.values) {
    for (final info in agent.abilities) {
      final ability = info.abilityData;
      if (ability != null && seenTypes.add(ability.runtimeType)) {
        yield info;
      }
    }
  }
}

PlacedAbility _placedAbility(AbilityInfo info, {String? id}) {
  return PlacedAbility(
    id: id ?? '${info.type.name}-${info.index}',
    data: info,
    position: const Offset(411.25, 287.75),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  group('ability widgetAnchor scaling', () {
    test('catalog covers every supported ability geometry type', () {
      final types = _representativeAbilityInfos()
          .map((info) => info.abilityData.runtimeType)
          .toSet();

      expect(
        types,
        containsAll(<Type>{
          BaseAbility,
          ImageAbility,
          CircleAbility,
          SectorCircleAbility,
          SquareAbility,
          CenterSquareAbility,
          RotatableImageAbility,
          ResizableSquareAbility,
          DeadlockBarrierMeshAbility,
        }),
      );
    });

    test('every ability type keeps its semantic anchor fixed at all sizes', () {
      const mapScale = 1.17;
      final coordinateSystem = CoordinateSystem.instance;

      for (final info in _representativeAbilityInfos()) {
        final placed = _placedAbility(info);
        Offset? expectedAnchor;

        for (final size in <double>{
          Settings.abilitySizeMin,
          Settings.abilitySize,
          Settings.abilitySizeMax,
        }) {
          final topLeft = screenPositionForWidget(
            widget: placed,
            coordinateSystem: coordinateSystem,
            mapScale: mapScale,
            abilitySize: size,
          );
          final renderedAnchor = info.abilityData!.getAnchorPoint(
            mapScale: mapScale,
            abilitySize: size,
          );
          final actualAnchor = topLeft +
              renderedAnchor.scale(
                coordinateSystem.scaleFactor,
                coordinateSystem.scaleFactor,
              );
          expectedAnchor ??= actualAnchor;

          expect(
            actualAnchor.dx,
            closeTo(expectedAnchor.dx, 0.0001),
            reason: '${info.abilityData.runtimeType} x at size $size',
          );
          expect(
            actualAnchor.dy,
            closeTo(expectedAnchor.dy, 0.0001),
            reason: '${info.abilityData.runtimeType} y at size $size',
          );
        }
      }
    });

    test('drag conversion round-trips stable serialized positions', () {
      const mapScale = 0.91;
      final coordinateSystem = CoordinateSystem.instance;

      for (final info in _representativeAbilityInfos()) {
        final placed = _placedAbility(info);
        Offset? expectedStoredPosition;
        for (final size in <double>{
          Settings.abilitySizeMin,
          Settings.abilitySizeMax,
        }) {
          final renderedTopLeft = screenPositionForWidget(
            widget: placed,
            coordinateSystem: coordinateSystem,
            mapScale: mapScale,
            abilitySize: size,
          );
          final restored = storedAbilityPositionForRenderedScreenPosition(
            ability: info.abilityData!,
            coordinateSystem: coordinateSystem,
            renderedScreenPosition: renderedTopLeft,
            mapScale: mapScale,
            abilitySize: size,
          );
          expectedStoredPosition ??= restored;

          expect(
            restored.dx,
            closeTo(expectedStoredPosition.dx, 0.0001),
            reason: '${info.abilityData.runtimeType} x at size $size',
          );
          expect(
            restored.dy,
            closeTo(expectedStoredPosition.dy, 0.0001),
            reason: '${info.abilityData.runtimeType} y at size $size',
          );
        }
      }
    });

    test('side switching is independent of the selected runtime size', () {
      const mapScale = 1.2;
      final sizeDependentInfos = _representativeAbilityInfos().where((info) {
        final ability = info.abilityData!;
        final minAnchor = ability.getAnchorPoint(
          mapScale: mapScale,
          abilitySize: Settings.abilitySizeMin,
        );
        final maxAnchor = ability.getAnchorPoint(
          mapScale: mapScale,
          abilitySize: Settings.abilitySizeMax,
        );
        return minAnchor != maxAnchor;
      });

      expect(sizeDependentInfos, isNotEmpty);
      for (final info in sizeDependentInfos) {
        final atMinimum = _placedAbility(info, id: 'minimum');
        final atMaximum = _placedAbility(info, id: 'maximum');

        atMinimum.switchSides(
          mapScale: mapScale,
          abilitySize: Settings.abilitySizeMin,
        );
        atMaximum.switchSides(
          mapScale: mapScale,
          abilitySize: Settings.abilitySizeMax,
        );

        expect(
          atMaximum.position,
          atMinimum.position,
          reason: '${info.abilityData.runtimeType}',
        );
      }
    });
  });

  group('agent-scaled widgetAnchor scaling', () {
    final representativeAgents = <PlacedAgentNode>[
      PlacedAgent(
        id: 'plain-agent',
        type: AgentType.jett,
        position: const Offset(318.5, 211.25),
      ),
      PlacedViewConeAgent(
        id: 'view-cone-agent',
        type: AgentType.sova,
        presetType: UtilityType.viewCone90,
        position: const Offset(318.5, 211.25),
      ),
      PlacedCircleAgent(
        id: 'circle-agent',
        type: AgentType.viper,
        position: const Offset(318.5, 211.25),
        diameterMeters: 12,
      ),
    ];

    test('every agent icon family keeps its center anchor fixed at all sizes',
        () {
      final coordinateSystem = CoordinateSystem.instance;

      for (final agent in representativeAgents) {
        Offset? expectedAnchor;
        for (final size in <double>{
          Settings.agentSizeMin,
          Settings.agentSize,
          Settings.agentSizeMax,
        }) {
          final topLeft = screenPositionForWidget(
            widget: agent,
            coordinateSystem: coordinateSystem,
            agentSize: size,
          );
          final actualAnchor = topLeft +
              Offset(size / 2, size / 2).scale(
                coordinateSystem.scaleFactor,
                coordinateSystem.scaleFactor,
              );
          expectedAnchor ??= actualAnchor;

          expect(
            actualAnchor.dx,
            closeTo(expectedAnchor.dx, 0.0001),
            reason: '${agent.runtimeType} x at size $size',
          );
          expect(
            actualAnchor.dy,
            closeTo(expectedAnchor.dy, 0.0001),
            reason: '${agent.runtimeType} y at size $size',
          );
        }
      }
    });

    test('agent drag conversion round-trips stable serialized positions', () {
      final coordinateSystem = CoordinateSystem.instance;

      for (final agent in representativeAgents) {
        Offset? expectedStoredPosition;
        for (final size in <double>{
          Settings.agentSizeMin,
          Settings.agentSizeMax,
        }) {
          final renderedTopLeft = screenPositionForWidget(
            widget: agent,
            coordinateSystem: coordinateSystem,
            agentSize: size,
          );
          final restored = storedAgentPositionForRenderedScreenPosition(
            coordinateSystem: coordinateSystem,
            renderedScreenPosition: renderedTopLeft,
            agentSize: size,
          );
          expectedStoredPosition ??= restored;

          expect(restored.dx, closeTo(expectedStoredPosition.dx, 0.0001));
          expect(restored.dy, closeTo(expectedStoredPosition.dy, 0.0001));
        }
      }
    });

    test('role icon utilities keep their semantic anchor fixed at all sizes',
        () {
      const mapScale = 1.13;
      final coordinateSystem = CoordinateSystem.instance;

      for (final type in UtilityType.values.where(UtilityData.isRoleIcon)) {
        final utility = PlacedUtility(
          id: 'role-${type.name}',
          type: type,
          position: const Offset(276.5, 163.75),
        );
        Offset? expectedAnchor;

        for (final size in <double>{
          Settings.agentSizeMin,
          Settings.agentSize,
          Settings.agentSizeMax,
        }) {
          final topLeft = screenPositionForWidget(
            widget: utility,
            coordinateSystem: coordinateSystem,
            mapScale: mapScale,
            agentSize: size,
            abilitySize: Settings.abilitySize,
          );
          final renderedAnchor = utilityAnchorForScale(
            utility: utility,
            mapScale: mapScale,
            agentSize: size,
            abilitySize: Settings.abilitySize,
          );
          final actualAnchor = topLeft +
              renderedAnchor.scale(
                coordinateSystem.scaleFactor,
                coordinateSystem.scaleFactor,
              );
          expectedAnchor ??= actualAnchor;

          expect(actualAnchor.dx, closeTo(expectedAnchor.dx, 0.0001));
          expect(actualAnchor.dy, closeTo(expectedAnchor.dy, 0.0001));
        }
      }
    });

    test('role icon drag conversion round-trips stable positions', () {
      const mapScale = 0.87;
      final coordinateSystem = CoordinateSystem.instance;
      final utility = PlacedUtility(
        id: 'role-icon',
        type: UtilityType.controller,
        position: const Offset(356.25, 194.5),
      );
      Offset? expectedStoredPosition;

      for (final size in <double>{
        Settings.agentSizeMin,
        Settings.agentSizeMax,
      }) {
        final renderedTopLeft = screenPositionForWidget(
          widget: utility,
          coordinateSystem: coordinateSystem,
          mapScale: mapScale,
          agentSize: size,
          abilitySize: Settings.abilitySize,
        );
        final restored = storedUtilityPositionForRenderedScreenPosition(
          utility: utility,
          coordinateSystem: coordinateSystem,
          renderedScreenPosition: renderedTopLeft,
          mapScale: mapScale,
          agentSize: size,
          abilitySize: Settings.abilitySize,
        );
        expectedStoredPosition ??= restored;

        expect(restored.dx, closeTo(expectedStoredPosition.dx, 0.0001));
        expect(restored.dy, closeTo(expectedStoredPosition.dy, 0.0001));
      }
    });

    test('side switching is independent of runtime agent scale', () {
      final atMinimum = representativeAgents.first.deepCopy<PlacedAgentNode>();
      final atMaximum = representativeAgents.first.deepCopy<PlacedAgentNode>();
      atMinimum.switchSides(Settings.agentSizeMin);
      atMaximum.switchSides(Settings.agentSizeMax);
      expect(atMaximum.position, atMinimum.position);

      final roleAtMinimum = PlacedUtility(
        id: 'role-min',
        type: UtilityType.initiator,
        position: const Offset(205, 305),
      );
      final roleAtMaximum = roleAtMinimum.copyWith(id: 'role-max');
      roleAtMinimum.switchSides(
        mapScale: 1,
        agentSize: Settings.agentSizeMin,
        abilitySize: Settings.abilitySizeMin,
      );
      roleAtMaximum.switchSides(
        mapScale: 1,
        agentSize: Settings.agentSizeMax,
        abilitySize: Settings.abilitySizeMax,
      );
      expect(roleAtMaximum.position, roleAtMinimum.position);
    });
  });

  test('ability size changes participate in transaction undo and redo', () {
    final container = ProviderContainer(
      overrides: [
        strategyProvider.overrideWith(_NoopStrategyProvider.new),
      ],
    );
    addTearDown(container.dispose);

    final settings = container.read(strategySettingsProvider.notifier);
    container.read(actionProvider.notifier).performTransaction(
      groups: const [ActionGroup.strategySettings],
      mutation: () => settings.updateAbilitySize(Settings.abilitySizeMax),
    );

    expect(
      container.read(strategySettingsProvider).abilitySize,
      Settings.abilitySizeMax,
    );
    expect(container.read(actionProvider), hasLength(1));
    expect(container.read(actionProvider).single.type, ActionType.transaction);

    container.read(actionProvider.notifier).undoAction();
    expect(
      container.read(strategySettingsProvider).abilitySize,
      Settings.abilitySize,
    );

    container.read(actionProvider.notifier).redoAction();
    expect(
      container.read(strategySettingsProvider).abilitySize,
      Settings.abilitySizeMax,
    );
  });

  test('agent size changes participate in transaction undo and redo', () {
    final container = ProviderContainer(
      overrides: [
        strategyProvider.overrideWith(_NoopStrategyProvider.new),
      ],
    );
    addTearDown(container.dispose);

    final settings = container.read(strategySettingsProvider.notifier);
    container.read(actionProvider.notifier).performTransaction(
      groups: const [ActionGroup.strategySettings],
      mutation: () => settings.updateAgentSize(Settings.agentSizeMax),
    );

    expect(
      container.read(strategySettingsProvider).agentSize,
      Settings.agentSizeMax,
    );
    expect(container.read(actionProvider), hasLength(1));
    expect(container.read(actionProvider).single.type, ActionType.transaction);

    container.read(actionProvider.notifier).undoAction();
    expect(
      container.read(strategySettingsProvider).agentSize,
      Settings.agentSize,
    );

    container.read(actionProvider.notifier).redoAction();
    expect(
      container.read(strategySettingsProvider).agentSize,
      Settings.agentSizeMax,
    );
  });
}
