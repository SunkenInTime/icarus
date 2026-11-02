import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
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
