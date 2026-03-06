import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_filter_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/favorite_agents_provider.dart';

class _NoopActionProvider extends ActionProvider {
  @override
  List<UserAction> build() => [];

  @override
  void addAction(UserAction action) {
    state = [...state, action];
  }
}

class _FakeFavoriteAgentsProvider extends FavoriteAgentsProvider {
  @override
  Set<AgentType> build() => <AgentType>{};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Agent duplication behavior', () {
    test('ctrl-duplicate creates a new agent id at drop position', () {
      CoordinateSystem(playAreaSize: const Size(1920, 1080));
      final container = ProviderContainer(
        overrides: [
          actionProvider.overrideWith(_NoopActionProvider.new),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(agentProvider.notifier);
      notifier.fromHive([
        PlacedAgent(
          id: 'source-agent-id',
          type: AgentType.jett,
          position: const Offset(180, 220),
          isAlly: true,
          state: AgentState.dead,
        ),
      ]);

      notifier.duplicateAgentAt(
        sourceId: 'source-agent-id',
        position: const Offset(300, 330),
      );

      final agents = container.read(agentProvider);
      expect(agents, hasLength(2));

      final source =
          agents.firstWhere((agent) => agent.id == 'source-agent-id');
      final duplicate =
          agents.firstWhere((agent) => agent.id != 'source-agent-id');

      expect(source.position, const Offset(180, 220));
      expect(duplicate.id, isNot('source-agent-id'));
      expect(duplicate.type, AgentType.jett);
      expect(duplicate.position, const Offset(300, 330));
      expect(duplicate.isAlly, isTrue);
      expect(duplicate.state, AgentState.dead);

      final lastAction = container.read(actionProvider).last;
      expect(lastAction.type, ActionType.addition);
      expect(lastAction.group, ActionGroup.agent);
      expect(lastAction.id, duplicate.id);
    });

    test('duplicate outside bounds is ignored', () {
      CoordinateSystem(playAreaSize: const Size(1920, 1080));
      final container = ProviderContainer(
        overrides: [
          actionProvider.overrideWith(_NoopActionProvider.new),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(agentProvider.notifier);
      notifier.fromHive([
        PlacedAgent(
          id: 'source-agent-id',
          type: AgentType.sova,
          position: const Offset(220, 220),
        ),
      ]);

      notifier.duplicateAgentAt(
        sourceId: 'source-agent-id',
        position: const Offset(-100, -100),
      );

      expect(container.read(agentProvider), hasLength(1));
      expect(container.read(actionProvider), isEmpty);
    });
  });

  group('Agent filter hotkey behavior', () {
    test('toggleAllOnMap alternates between all and on-map', () {
      final container = ProviderContainer(
        overrides: [
          favoriteAgentsProvider.overrideWith(_FakeFavoriteAgentsProvider.new),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(agentFilterProvider.notifier);

      expect(
        container.read(agentFilterProvider).currentFilter,
        FilterState.all,
      );

      notifier.toggleAllOnMap();
      expect(
        container.read(agentFilterProvider).currentFilter,
        FilterState.onMap,
      );

      notifier.toggleAllOnMap();
      expect(
        container.read(agentFilterProvider).currentFilter,
        FilterState.all,
      );
    });
  });
}
