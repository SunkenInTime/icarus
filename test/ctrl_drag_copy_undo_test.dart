import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';

class _NoopStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() => StrategyState(
        isSaved: true,
        stratName: null,
        id: 'ctrl-drag-test',
        storageDirectory: null,
        activePageId: null,
      );

  @override
  void setUnsaved() {}
}

ProviderContainer _createContainer() {
  final container = ProviderContainer(
    overrides: [
      strategyProvider.overrideWith(_NoopStrategyProvider.new),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

final _breachAbility = AgentData.agents[AgentType.breach]!.abilities.first;

// The two calls a Ctrl-drag makes (placed_widget_builder.dart and the
// placed agent and ability widgets): copy at drag start, move on drop.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  group('one undo takes back a Ctrl-drag copy', () {
    test('agent', () {
      final container = _createContainer();
      final agents = container.read(agentProvider.notifier);
      final actions = container.read(actionProvider.notifier);
      agents.fromHive([
        PlacedAgent(
          id: 'src',
          type: AgentType.jett,
          position: const Offset(900, 500),
        ),
      ]);

      final copy = agents.duplicateAgentAt(
          sourceId: 'src', position: const Offset(900, 500))!;
      agents.updatePosition(const Offset(600, 500), copy);
      expect(container.read(agentProvider), hasLength(2));

      actions.undoAction();
      expect(container.read(agentProvider).map((a) => a.id), ['src']);
      expect(container.read(agentProvider).single.position,
          const Offset(900, 500));

      actions.redoAction();
      final redone =
          container.read(agentProvider).firstWhere((a) => a.id == copy);
      expect(redone.position, const Offset(600, 500));

      actions.undoAction();
      expect(container.read(agentProvider).map((a) => a.id), ['src']);
    });

    test('ability', () {
      final container = _createContainer();
      final abilities = container.read(abilityProvider.notifier);
      final actions = container.read(actionProvider.notifier);
      abilities.fromHive([
        PlacedAbility(
          id: 'src',
          data: _breachAbility,
          position: const Offset(900, 500),
        ),
      ]);

      final copy = abilities.duplicateAbilityAt(
          sourceId: 'src', position: const Offset(900, 500))!;
      abilities.updatePosition(const Offset(600, 500), copy);
      expect(container.read(abilityProvider), hasLength(2));

      actions.undoAction();
      expect(container.read(abilityProvider).map((a) => a.id), ['src']);
    });
  });

  test('a copy dropped off the map leaves nothing to undo', () {
    final container = _createContainer();
    final agents = container.read(agentProvider.notifier);
    final actions = container.read(actionProvider.notifier);
    agents.fromHive([
      PlacedAgent(
        id: 'src',
        type: AgentType.jett,
        position: const Offset(900, 500),
      ),
    ]);
    agents.updatePosition(const Offset(800, 500), 'src');

    final copy = agents.duplicateAgentAt(
        sourceId: 'src', position: const Offset(800, 500))!;
    agents.updatePosition(const Offset(-5000, -5000), copy);
    expect(container.read(agentProvider).map((a) => a.id), ['src']);

    // The one undo left is the move made before the copy.
    actions.undoAction();
    expect(
        container.read(agentProvider).single.position, const Offset(900, 500));
    expect(container.read(actionProvider), isEmpty);
  });

  test('a later move of the copy is its own undo step', () {
    final container = _createContainer();
    final agents = container.read(agentProvider.notifier);
    final actions = container.read(actionProvider.notifier);
    agents.fromHive([
      PlacedAgent(
        id: 'src',
        type: AgentType.jett,
        position: const Offset(900, 500),
      ),
    ]);

    final copy = agents.duplicateAgentAt(
        sourceId: 'src', position: const Offset(900, 500))!;
    agents.updatePosition(const Offset(600, 500), copy);
    agents.updatePosition(const Offset(700, 400), copy);

    actions.undoAction();
    expect(
      container.read(agentProvider).firstWhere((a) => a.id == copy).position,
      const Offset(600, 500),
    );
    actions.undoAction();
    expect(container.read(agentProvider).map((a) => a.id), ['src']);
  });
}
