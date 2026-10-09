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

  test('editing placement moves lineups that share a spot together', () {
    final container = _container();
    PlacedAbility ability(String id, Offset position) => PlacedAbility(
          id: id,
          data: AgentData.agents[AgentType.jett]!.abilities.first,
          position: position,
        );
    final lineUps = container.read(lineUpProvider.notifier)
      ..fromHive(
        LineUpGraph(
          origins: [
            LineUpOrigin(
                id: 'shared', agent: _agent('a1', const Offset(10, 10))),
            LineUpOrigin(
                id: 'apart', agent: _agent('a2', const Offset(90, 10))),
          ],
          landings: [
            LineUpLanding(
                id: 'l1', ability: ability('b1', const Offset(20, 80))),
            LineUpLanding(
                id: 'l2', ability: ability('b2', const Offset(40, 80))),
            LineUpLanding(
                id: 'l3', ability: ability('b3', const Offset(90, 80))),
          ],
          links: [
            LineUpLink(id: 'k1', originId: 'shared', landingId: 'l1'),
            LineUpLink(id: 'k2', originId: 'shared', landingId: 'l2'),
            LineUpLink(id: 'k3', originId: 'apart', landingId: 'l3'),
          ],
        ),
      );
    final history = container.read(actionProvider.notifier);
    Offset origin(String id) =>
        container.read(lineUpProvider).originById(id)!.agent.position;
    Offset landing(String id) =>
        container.read(lineUpProvider).landingById(id)!.ability.position;

    // Picking one lineup takes the one that throws from the same spot too,
    // and nothing else.
    lineUps.startEdit('k1');
    final edit = container.read(lineUpProvider).edit!;
    expect(edit.linkIds, {'k1', 'k2'});
    expect(edit.originIds, {'shared'});
    expect(edit.landingIds, {'l1', 'l2'});
    expect(container.read(lineUpProvider).editMovesAnything, isFalse);

    // Drafts move nothing until saved.
    lineUps.moveEditedOrigin('shared', const Offset(30, 30));
    lineUps.moveEditedLanding('l2', const Offset(60, 120));
    expect(origin('shared'), const Offset(10, 10));
    expect(container.read(lineUpProvider).editMovesAnything, isTrue);

    lineUps.saveEdit();
    expect(container.read(lineUpProvider).edit, isNull);
    expect(origin('shared'), const Offset(30, 30));
    expect(landing('l1'), const Offset(20, 80));
    expect(landing('l2'), const Offset(60, 120));
    // Still one marker for both lineups: nothing split.
    expect(
      container.read(lineUpProvider).links.map((link) => link.originId),
      ['shared', 'shared', 'apart'],
    );
    expect(container.read(actionProvider), hasLength(1));

    history.undoAction();
    expect(origin('shared'), const Offset(10, 10));
    expect(landing('l2'), const Offset(40, 80));

    history.redoAction();
    expect(origin('shared'), const Offset(30, 30));
    expect(landing('l2'), const Offset(60, 120));
  });

  test('cancelling a placement edit leaves every lineup where it was', () {
    final container = _container();
    final lineUps = container.read(lineUpProvider.notifier)
      ..fromHive(
        LineUpGraph(
          origins: [
            LineUpOrigin(id: 'o', agent: _agent('a', const Offset(10, 10))),
          ],
          landings: [
            LineUpLanding(
              id: 'l',
              ability: PlacedAbility(
                id: 'b',
                data: AgentData.agents[AgentType.jett]!.abilities.first,
                position: const Offset(20, 80),
              ),
            ),
          ],
          links: [LineUpLink(id: 'k', originId: 'o', landingId: 'l')],
        ),
      );

    lineUps.startEdit('k');
    lineUps.moveEditedOrigin('o', const Offset(300, 300));
    lineUps.cancelEdit();

    expect(container.read(lineUpProvider).edit, isNull);
    expect(
      container.read(lineUpProvider).originById('o')!.agent.position,
      const Offset(10, 10),
    );
    expect(container.read(actionProvider), isEmpty);
  });

  LineUpGraph oneLineup() => LineUpGraph(
        origins: [
          LineUpOrigin(id: 'o', agent: _agent('a', const Offset(10, 10))),
        ],
        landings: [
          LineUpLanding(
            id: 'l',
            ability: PlacedAbility(
              id: 'b',
              data: AgentData.agents[AgentType.jett]!.abilities.first,
              position: const Offset(20, 80),
            ),
          ),
        ],
        links: [LineUpLink(id: 'k', originId: 'o', landingId: 'l')],
      );

  test('saving a placement edit keeps an undo made while it was open', () {
    final container = _container();
    final lineUps = container.read(lineUpProvider.notifier)
      ..fromHive(oneLineup());
    final history = container.read(actionProvider.notifier);
    LineUpState lineUpState() => container.read(lineUpProvider);

    lineUps
      ..startEdit('k')
      ..moveEditedOrigin('o', const Offset(50, 50))
      ..saveEdit();
    // A second edit moves only the landing; the origin move is undone
    // before it is saved.
    lineUps
      ..startEdit('k')
      ..moveEditedLanding('l', const Offset(90, 90));
    history.undoAction();
    expect(lineUpState().originById('o')!.agent.position, const Offset(10, 10));

    lineUps.saveEdit();
    expect(lineUpState().originById('o')!.agent.position, const Offset(10, 10));
    expect(
      lineUpState().landingById('l')!.ability.position,
      const Offset(90, 90),
    );
  });

  test('opening another page ends a placement edit without saving it', () {
    final container = _container();
    final lineUps = container.read(lineUpProvider.notifier)
      ..fromHive(oneLineup());

    lineUps
      ..startEdit('k')
      ..moveEditedOrigin('o', const Offset(50, 50));
    // A copied page holds lineups with the same ids.
    lineUps.fromHive(oneLineup());
    lineUps.saveEdit();

    expect(container.read(lineUpProvider).edit, isNull);
    expect(
      container.read(lineUpProvider).originById('o')!.agent.position,
      const Offset(10, 10),
    );
    expect(container.read(actionProvider), isEmpty);
  });

  test('one undo steps past entries that change nothing to one that does', () {
    final container = _container();
    final agents = container.read(agentProvider.notifier)
      ..fromHive([
        _agent('sova', const Offset(10, 10)),
        _agent('jett', const Offset(20, 20)),
      ]);
    final history = container.read(actionProvider.notifier);

    agents.updatePosition(const Offset(100, 100), 'sova');
    agents.updatePosition(const Offset(200, 200), 'jett');
    // Jett goes without a history entry, as a teammate's deletion does
    // before history is reconciled.
    agents.removeAgent('jett');

    history.undoAction();
    expect(container.read(agentProvider).single.position, const Offset(10, 10));
    expect(container.read(actionProvider), isEmpty);

    history.redoAction();
    expect(
        container.read(agentProvider).single.position, const Offset(100, 100));
  });

  test('alternating clears keep history growing linearly', () {
    final container = _container();
    final history = container.read(actionProvider.notifier);
    int retained(Iterable<UserAction> actions) => actions.fold(
          0,
          (count, action) => count + 1 + retained(action.changes),
        );

    for (var i = 0; i < 20; i++) {
      container
          .read(agentProvider.notifier)
          .addAgent(_agent('agent-$i', const Offset(10, 10)));
      container.read(utilityProvider.notifier).addUtility(PlacedUtility(
            id: 'utility-$i',
            type: UtilityType.viewCone90,
            position: const Offset(40, 40),
          ));
      history.clearGroupAsAction(
        i.isEven ? ActionGroup.agent : ActionGroup.utility,
      );
    }

    // Each round adds two objects and one clear of at most two of them.
    expect(
      retained([...container.read(actionProvider), ...history.poppedItems]),
      lessThanOrEqualTo(20 * 5),
    );
  });

  test('history keeps the most recent steps up to its limit', () {
    final container = _container();
    final agents = container.read(agentProvider.notifier)
      ..fromHive([_agent('jett', const Offset(0, 0))]);

    for (var i = 1; i <= ActionProvider.historyLimit + 10; i++) {
      agents.updatePosition(Offset(i.toDouble(), 0), 'jett');
    }

    final steps = container.read(actionProvider);
    expect(steps, hasLength(ActionProvider.historyLimit));
    // The oldest ten went; the first kept step moved Jett from x = 10.
    expect(
        steps.first.objectDelta!.before!.agent!.position, const Offset(10, 0));
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
