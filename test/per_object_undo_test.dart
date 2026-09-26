import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
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

  test('deleting a link into a shared landing undoes and redoes cleanly', () {
    final container = _container();
    final lineUps = container.read(lineUpProvider.notifier)
      ..fromHive(
        LineUpGraph(
          origins: [
            LineUpOrigin(id: 'o1', agent: _agent('a1', const Offset(10, 10))),
            LineUpOrigin(id: 'o2', agent: _agent('a2', const Offset(90, 10))),
          ],
          landings: [
            LineUpLanding(
              id: 'shared',
              ability: PlacedAbility(
                id: 'ability',
                data: AgentData.agents[AgentType.jett]!.abilities.first,
                position: const Offset(50, 80),
              ),
            ),
          ],
          links: [
            LineUpLink(id: 'k1', originId: 'o1', landingId: 'shared'),
            LineUpLink(id: 'k2', originId: 'o2', landingId: 'shared'),
          ],
        ),
      );
    final history = container.read(actionProvider.notifier);
    List<String> ids(Iterable<Object> entries) => [
          for (final entry in entries)
            switch (entry) {
              LineUpOrigin(:final id) => id,
              LineUpLanding(:final id) => id,
              LineUpLink(:final id) => id,
              _ => '?',
            },
        ];
    void expectGraph(List<String> origins, List<String> links) {
      final graph = container.read(lineUpProvider);
      expect(ids(graph.origins), unorderedEquals(origins));
      expect(ids(graph.landings), ['shared']);
      expect(ids(graph.links), unorderedEquals(links));
    }

    lineUps.deleteLink('k1');
    expectGraph(['o2'], ['k2']);

    history.undoAction();
    expectGraph(['o1', 'o2'], ['k1', 'k2']);
    expect(container.read(lineUpProvider).linkById('k1')!.landingId, 'shared');

    history.redoAction();
    expectGraph(['o2'], ['k2']);

    history.undoAction();
    expectGraph(['o1', 'o2'], ['k1', 'k2']);
    expect(history.poppedItems, hasLength(1));
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
