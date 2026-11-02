import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/draggable_widgets/agents/detach_from_agent.dart';

class _NoopStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() {
    return const StrategyState(
      strategyId: 'test-strategy',
      strategyName: null,
      source: StrategySource.local,
      storageDirectory: null,
      isOpen: true,
    );
  }

  @override
  void setUnsaved() {}
}

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [strategyProvider.overrideWith(_NoopStrategyProvider.new)],
  );
  addTearDown(container.dispose);
  return container;
}

/// The middle of [widget] as the canvas draws it: its screen top-left from
/// the drawing path, plus its drawn anchor.
Offset _drawnMiddle(
  PlacedWidget widget, {
  required double mapScale,
  required double agentSize,
  required double abilitySize,
  required bool isAttack,
}) {
  final coordinateSystem = CoordinateSystem.instance;
  final topLeft = screenPositionForWidget(
    widget: widget,
    coordinateSystem: coordinateSystem,
    mapScale: mapScale,
    agentSize: agentSize,
    abilitySize: abilitySize,
    isAttack: isAttack,
  );
  final anchor = switch (widget) {
    PlacedUtility() => utilityAnchorForScale(
        utility: widget,
        mapScale: mapScale,
        agentSize: agentSize,
        abilitySize: abilitySize,
      ),
    _ => Offset(agentSize / 2, agentSize / 2),
  };
  return topLeft +
      anchor.scale(coordinateSystem.scaleFactor, coordinateSystem.scaleFactor);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => CoordinateSystem(playAreaSize: const Size(1920, 1080)));

  test('detaching a circle leaves a free circle on the agent, one undo step',
      () {
    final container = _container();
    final agent = PlacedCircleAgent(
      id: 'sova',
      type: AgentType.sova,
      position: const Offset(300, 200),
      diameterMeters: 9,
      colorValue: 0xFF22C55E,
      opacityPercent: 30,
      isAlly: false,
    )..caption = 'watch heaven';
    container.read(agentProvider.notifier).fromHive([agent]);

    detachFromAgent(container.read, agent);

    final plain = container.read(agentProvider).single;
    expect(plain, isA<PlacedAgent>());
    expect(plain.id, 'sova');
    expect(plain.position, agent.position);
    expect(plain.isAlly, isFalse);
    expect(plain.caption, 'watch heaven');
    final circle = container.read(utilityProvider).single;
    expect(circle.type, UtilityType.customCircle);
    expect(circle.customDiameter, 9);
    expect(circle.customColorValue, 0xFF22C55E);
    expect(circle.customOpacityPercent, 30);

    container.read(actionProvider.notifier).undoAction();
    expect(container.read(agentProvider).single, isA<PlacedCircleAgent>());
    expect(container.read(utilityProvider), isEmpty);

    container.read(actionProvider.notifier).redoAction();
    expect(container.read(agentProvider).single, isA<PlacedAgent>());
    expect(container.read(utilityProvider), hasLength(1));
  });

  test('detaching a cone keeps where it points, how far and how high', () {
    final container = _container();
    final agent = PlacedViewConeAgent(
      id: 'cypher',
      type: AgentType.cypher,
      position: const Offset(500, 420),
      presetType: UtilityType.viewCone90,
      rotation: 1.2,
      length: 80,
      visionElevation: 150,
    );
    container.read(agentProvider.notifier).fromHive([agent]);

    detachFromAgent(container.read, agent);

    expect(container.read(agentProvider).single, isA<PlacedAgent>());
    final cone = container.read(utilityProvider).single;
    expect(cone.type, UtilityType.viewCone90);
    expect(cone.rotation, 1.2);
    expect(cone.length, 80);
    expect(cone.visionElevation, 150);
    expect(cone.isFullCircleCone, isFalse);

    container.read(actionProvider.notifier).undoAction();
    expect(container.read(agentProvider).single, isA<PlacedViewConeAgent>());
    expect(container.read(utilityProvider), isEmpty);
  });

  test('a detached circle or cone is drawn on the agent it came off', () {
    for (final map in [MapValue.ascent, MapValue.bind, MapValue.lotus]) {
      for (final isAttack in [true, false]) {
        for (final attached in <PlacedAgentNode>[
          PlacedCircleAgent(
            id: 'circle',
            type: AgentType.sova,
            position: const Offset(310, 140),
            diameterMeters: 12,
            colorValue: 0xFF22C55E,
            opacityPercent: 30,
          ),
          PlacedViewConeAgent(
            id: 'cone',
            type: AgentType.cypher,
            position: const Offset(610, 380),
            presetType: UtilityType.viewCone40,
            rotation: 0.7,
            length: 60,
          ),
        ]) {
          final container = _container();
          container.read(mapProvider.notifier).fromHive(map, isAttack);
          container.read(agentProvider.notifier).fromHive([attached]);

          detachFromAgent(container.read, attached);

          final mapScale = Maps.mapScale[map]!;
          // Marker sizes other than the ones positions are saved at.
          for (final (agentSize, abilitySize) in [(35.0, 25.0), (50.0, 40.0)]) {
            Offset middle(PlacedWidget widget) => _drawnMiddle(
                  widget,
                  mapScale: mapScale,
                  agentSize: agentSize,
                  abilitySize: abilitySize,
                  isAttack: isAttack,
                );
            final drift = middle(container.read(utilityProvider).single) -
                middle(container.read(agentProvider).single);
            expect(
              drift.distance,
              lessThan(0.01),
              reason: '${attached.id} on ${map.name}, '
                  '${isAttack ? 'attack' : 'defense'}, agent size $agentSize',
            );
          }
        }
      }
    }
  });

  test('a plain agent has nothing to detach', () {
    final container = _container();
    final agent = PlacedAgent(
      id: 'jett',
      type: AgentType.jett,
      position: const Offset(10, 10),
    );
    container.read(agentProvider.notifier).fromHive([agent]);

    detachFromAgent(container.read, agent);

    expect(container.read(utilityProvider), isEmpty);
    expect(container.read(actionProvider), isEmpty);
  });
}
