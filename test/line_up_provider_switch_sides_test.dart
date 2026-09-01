import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/action_provider.dart';

class _NoopActionProvider extends ActionProvider {
  @override
  List<UserAction> build() => [];

  @override
  void addAction(UserAction action) {}
}

void main() {
  test('locked add-item mode keeps the group agent canonical', () {
    final container = ProviderContainer(
      overrides: [actionProvider.overrideWith(_NoopActionProvider.new)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(lineUpProvider.notifier);
    final group = LineUpGroup(
      id: 'group-1',
      agent: PlacedAgent(
        id: 'group-agent',
        type: AgentType.breach,
        position: const Offset(120, 220),
      ),
      items: const [],
    );

    notifier.addGroup(group);
    notifier.startNewItemForGroup(group.id);

    final state = container.read(lineUpProvider);
    expect(state.currentGroupId, group.id);
    expect(state.placementMode, LineUpPlacementMode.addItemToGroup);
    expect(state.lockedAgentType, AgentType.breach);
    expect(state.currentAgent, isNull);
    expect(notifier.getCurrentPreviewAgent()?.position, const Offset(120, 220));
  });

  test('matching abilities retain canonical positions in locked mode', () {
    final container = ProviderContainer(
      overrides: [actionProvider.overrideWith(_NoopActionProvider.new)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(lineUpProvider.notifier);
    final group = LineUpGroup(
      id: 'group-2',
      agent: PlacedAgent(
        id: 'group-agent',
        type: AgentType.breach,
        position: const Offset(120, 220),
      ),
      items: const [],
    );
    final ability = PlacedAbility(
      id: 'new-ability',
      data: AgentData.agents[AgentType.breach]!.abilities.first,
      position: const Offset(300, 400),
    );

    notifier.addGroup(group);
    notifier.startNewItemForGroup(group.id);
    notifier.setCurrentAbility(ability);

    final current = container.read(lineUpProvider).currentAbility;
    expect(current?.position, const Offset(300, 400));
    expect(current?.lineUpID, group.id);
  });
}
