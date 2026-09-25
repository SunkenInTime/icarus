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

PlacedAgent _agent(String id, Offset position) =>
    PlacedAgent(id: id, type: AgentType.jett, position: position);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => CoordinateSystem(playAreaSize: const Size(1920, 1080)));

  test('undoing a clear puts objects back in their stacking order', () {
    final container = _container();
    container.read(agentProvider.notifier).fromHive([
      _agent('bottom', const Offset(10, 10)),
      _agent('middle', const Offset(20, 20)),
      _agent('top', const Offset(30, 30)),
    ]);
    final history = container.read(actionProvider.notifier);

    history.clearGroupAsAction(ActionGroup.agent);
    history.undoAction();

    expect(
      container.read(agentProvider).map((agent) => agent.id),
      ['bottom', 'middle', 'top'],
    );
  });

  test('a utility elevation change undoes after a later move is undone', () {
    final container = _container();
    final utilities = container.read(utilityProvider.notifier)
      ..fromHive([
        PlacedUtility(
          id: 'cone',
          type: UtilityType.viewCone90,
          position: const Offset(40, 40),
        ),
      ]);
    final history = container.read(actionProvider.notifier);

    utilities.updateViewConeElevation('cone', 150);
    utilities.updatePosition(const Offset(90, 90), 'cone');
    history.undoAction();
    history.undoAction();

    final cone = container.read(utilityProvider).single;
    expect(cone.position, const Offset(40, 40));
    expect(cone.visionElevation, isNull);

    history.redoAction();
    expect(container.read(utilityProvider).single.visionElevation, 150);
  });

  test('a transaction that changes nothing adds no undo step', () {
    final container = _container();
    container
        .read(agentProvider.notifier)
        .fromHive([_agent('jett', const Offset(10, 10))]);

    container.read(actionProvider.notifier).performTransaction(
          groups: const [ActionGroup.agent],
          // Not a view cone agent, so there is nothing to convert.
          mutation: () => container
              .read(agentProvider.notifier)
              .convertViewConeAgentToPlain(id: 'jett'),
        );

    expect(container.read(actionProvider), isEmpty);
  });
}
