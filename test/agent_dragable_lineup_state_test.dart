import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/ability_bar_provider.dart';
import 'package:icarus/providers/favorite_agents_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/widgets/sidebar_widgets/agent_dragable.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _FakeFavoriteAgentsProvider extends FavoriteAgentsProvider {
  @override
  Set<AgentType> build() => <AgentType>{};
}

ProviderContainer _createContainer() {
  final container = ProviderContainer(
    overrides: [
      favoriteAgentsProvider.overrideWith(_FakeFavoriteAgentsProvider.new),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pumpHarness(
  WidgetTester tester, {
  required ProviderContainer container,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: ShadApp(
        home: Scaffold(
          body: Row(
            children: [
              SizedBox.square(
                dimension: 64,
                child:
                    AgentDragable(agent: AgentData.agents[AgentType.breach]!),
              ),
              const SizedBox(width: 8),
              SizedBox.square(
                dimension: 64,
                child: AgentDragable(agent: AgentData.agents[AgentType.sova]!),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _opacityFinder(AgentType type) {
  return find.byKey(ValueKey('agent-dim-opacity-${type.name}'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  testWidgets('regular lineup placement dims non-active agents',
      (tester) async {
    final container = _createContainer();
    container.read(lineUpProvider.notifier).startNewGroup(
          PlacedAgent(
            id: 'breach-agent',
            type: AgentType.breach,
            position: const Offset(100, 100),
            isAlly: true,
          ),
        );
    container
        .read(interactionStateProvider.notifier)
        .update(InteractionState.lineUpPlacing);

    await _pumpHarness(tester, container: container);

    expect(
      tester.widget<AnimatedOpacity>(_opacityFinder(AgentType.breach)).opacity,
      1,
    );
    expect(
      tester.widget<AnimatedOpacity>(_opacityFinder(AgentType.sova)).opacity,
      0.4,
    );
  });

  testWidgets('regular lineup placement does not disable non-active agents',
      (tester) async {
    final container = _createContainer();
    container.read(lineUpProvider.notifier).startNewGroup(
          PlacedAgent(
            id: 'breach-agent',
            type: AgentType.breach,
            position: const Offset(100, 100),
            isAlly: true,
          ),
        );
    container
        .read(interactionStateProvider.notifier)
        .update(InteractionState.lineUpPlacing);

    await _pumpHarness(tester, container: container);

    await tester.tap(find.byType(InkWell).at(1), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(container.read(abilityBarProvider)?.type, AgentType.sova);
  });

  testWidgets('locked add-item mode dims non-active agents', (tester) async {
    final container = _createContainer();
    final group = LineUpGroup(
      id: 'breach-group',
      agent: PlacedAgent(
        id: 'breach-agent',
        type: AgentType.breach,
        position: const Offset(100, 100),
        isAlly: true,
      ),
      items: [
        LineUpItem(
          id: 'breach-item',
          ability: PlacedAbility(
            id: 'breach-ability',
            data: AgentData.agents[AgentType.breach]!.abilities.first,
            position: const Offset(200, 200),
            isAlly: true,
          ),
        ),
      ],
    );
    container.read(lineUpProvider.notifier).addGroup(group);
    container.read(lineUpProvider.notifier).startNewItemForGroup(group.id);
    container
        .read(interactionStateProvider.notifier)
        .update(InteractionState.lineUpPlacing);

    await _pumpHarness(tester, container: container);

    expect(
      tester.widget<AnimatedOpacity>(_opacityFinder(AgentType.breach)).opacity,
      1,
    );
    expect(
      tester.widget<AnimatedOpacity>(_opacityFinder(AgentType.sova)).opacity,
      0.4,
    );
  });

  testWidgets('locked add-item mode blocks non-active tap', (tester) async {
    final container = _createContainer();
    final group = LineUpGroup(
      id: 'breach-group',
      agent: PlacedAgent(
        id: 'breach-agent',
        type: AgentType.breach,
        position: const Offset(100, 100),
        isAlly: true,
      ),
      items: [
        LineUpItem(
          id: 'breach-item',
          ability: PlacedAbility(
            id: 'breach-ability',
            data: AgentData.agents[AgentType.breach]!.abilities.first,
            position: const Offset(200, 200),
            isAlly: true,
          ),
        ),
      ],
    );
    container.read(lineUpProvider.notifier).addGroup(group);
    container
        .read(abilityBarProvider.notifier)
        .updateData(AgentData.agents[AgentType.breach]!);
    container.read(lineUpProvider.notifier).startNewItemForGroup(group.id);
    container
        .read(interactionStateProvider.notifier)
        .update(InteractionState.lineUpPlacing);

    await _pumpHarness(tester, container: container);

    await tester.tap(find.byType(InkWell).at(1), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(container.read(abilityBarProvider)?.type, AgentType.breach);
  });

  testWidgets('locked add-item mode blocks non-active drag start',
      (tester) async {
    final container = _createContainer();
    final group = LineUpGroup(
      id: 'breach-group',
      agent: PlacedAgent(
        id: 'breach-agent',
        type: AgentType.breach,
        position: const Offset(100, 100),
        isAlly: true,
      ),
      items: [
        LineUpItem(
          id: 'breach-item',
          ability: PlacedAbility(
            id: 'breach-ability',
            data: AgentData.agents[AgentType.breach]!.abilities.first,
            position: const Offset(200, 200),
            isAlly: true,
          ),
        ),
      ],
    );
    container.read(lineUpProvider.notifier).addGroup(group);
    container.read(lineUpProvider.notifier).startNewItemForGroup(group.id);
    container
        .read(interactionStateProvider.notifier)
        .update(InteractionState.lineUpPlacing);

    await _pumpHarness(tester, container: container);

    await tester.drag(
      find.byType(InkWell).at(1),
      const Offset(30, 0),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    expect(container.read(dragNotifier), isFalse);
  });

  testWidgets('active agent remains visually selected in locked mode',
      (tester) async {
    final container = _createContainer();
    final breachAgent = AgentData.agents[AgentType.breach]!;
    final group = LineUpGroup(
      id: 'breach-group',
      agent: PlacedAgent(
        id: 'breach-agent',
        type: AgentType.breach,
        position: const Offset(100, 100),
        isAlly: true,
      ),
      items: [
        LineUpItem(
          id: 'breach-item',
          ability: PlacedAbility(
            id: 'breach-ability',
            data: breachAgent.abilities.first,
            position: const Offset(200, 200),
            isAlly: true,
          ),
        ),
      ],
    );
    container.read(lineUpProvider.notifier).addGroup(group);
    container.read(abilityBarProvider.notifier).updateData(breachAgent);
    container.read(lineUpProvider.notifier).startNewItemForGroup(group.id);
    container
        .read(interactionStateProvider.notifier)
        .update(InteractionState.lineUpPlacing);

    await _pumpHarness(tester, container: container);

    final coloredBoxes = tester.widgetList<ColoredBox>(
      find.descendant(
        of: find.byType(AgentDragable).first,
        matching: find.byType(ColoredBox),
      ),
    );

    expect(
      coloredBoxes.single.color,
      Settings.tacticalVioletTheme.primary,
    );
    expect(
      tester.widget<AnimatedOpacity>(_opacityFinder(AgentType.breach)).opacity,
      1,
    );
  });
}
