import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_bar_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/canvas_resize_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/placed_ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/line_up_placer.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

class _TestActionProvider extends ActionProvider {
  @override
  List<UserAction> build() => [];

  @override
  void addAction(UserAction action) {
    poppedItems = [];
    state = [...state, action];
  }
}

class _FixedMapProvider extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.bind, isAttack: true);

  @override
  void fromHive(MapValue map, bool isAttack) {}
}

class _AgentDragSource extends StatelessWidget {
  const _AgentDragSource({required this.agent});

  final AgentData agent;

  @override
  Widget build(BuildContext context) {
    return Draggable<AgentData>(
      data: agent,
      feedback: const Material(
        color: Colors.transparent,
        child: SizedBox(width: 40, height: 40),
      ),
      childWhenDragging: const SizedBox(width: 40, height: 40),
      child: const ColoredBox(
        color: Colors.blue,
        child: SizedBox(width: 40, height: 40),
      ),
    );
  }
}

class _AbilityDragSource extends StatelessWidget {
  const _AbilityDragSource({required this.ability});

  final AbilityInfo ability;

  @override
  Widget build(BuildContext context) {
    return Draggable<AbilityInfo>(
      data: ability,
      feedback: const Material(
        color: Colors.transparent,
        child: SizedBox(width: 40, height: 40),
      ),
      childWhenDragging: const SizedBox(width: 40, height: 40),
      child: const ColoredBox(
        color: Colors.green,
        child: SizedBox(width: 40, height: 40),
      ),
    );
  }
}

ProviderContainer _createContainer() {
  final container = ProviderContainer(
    overrides: [
      actionProvider.overrideWith(_TestActionProvider.new),
      mapProvider.overrideWith(_FixedMapProvider.new),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

LineUpGroup _breachGroup() {
  return LineUpGroup(
    id: 'breach-group',
    agent: PlacedAgent(
      id: 'breach-agent',
      type: AgentType.breach,
      position: const Offset(180, 220),
      isAlly: true,
    ),
    items: [
      LineUpItem(
        id: 'breach-item',
        ability: PlacedAbility(
          id: 'breach-ability',
          data: AgentData.agents[AgentType.breach]!.abilities.first,
          position: const Offset(320, 360),
          isAlly: true,
        ),
      ),
    ],
  );
}

Future<void> _pumpHarness(
  WidgetTester tester, {
  required ProviderContainer container,
  required Widget child,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: ToastificationWrapper(
        child: ShadApp(
          home: Scaffold(body: child),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _pumpLineupCanvas(
  WidgetTester tester, {
  required ProviderContainer container,
  required double width,
  required double height,
}) async {
  CoordinateSystem(playAreaSize: Size(width, height));
  container.read(canvasResizeProvider.notifier).increment();
  await _pumpHarness(
    tester,
    container: container,
    child: SizedBox(
      width: width,
      height: height,
      child: const LineupPositionWidget(),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  testWidgets(
      'right-click Add Lineup Item populates ability bar and enters lineup mode',
      (tester) async {
    final container = _createContainer();
    final group = _breachGroup();
    container.read(lineUpProvider.notifier).addGroup(group);

    await _pumpHarness(
      tester,
      container: container,
      child: Center(
        child: AgentWidget(
          lineUpId: group.id,
          id: group.agent.id,
          isAlly: group.agent.isAlly,
          agent: AgentData.agents[group.agent.type]!,
        ),
      ),
    );

    await tester.tapAt(
      tester.getCenter(find.byType(AgentWidget)),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add Lineup Item'));
    await tester.pumpAndSettle();

    expect(container.read(interactionStateProvider),
        InteractionState.lineUpPlacing);
    expect(container.read(abilityBarProvider)?.type, AgentType.breach);
    expect(container.read(lineUpProvider).currentGroupId, group.id);
    expect(
      container.read(lineUpProvider).placementMode,
      LineUpPlacementMode.addItemToGroup,
    );
  });

  testWidgets('locked add-item mode renders a non-draggable preview agent',
      (tester) async {
    final container = _createContainer();
    final group = _breachGroup();
    container.read(lineUpProvider.notifier).addGroup(group);
    container.read(lineUpProvider.notifier).startNewItemForGroup(group.id);

    await _pumpHarness(
      tester,
      container: container,
      child: const SizedBox(
        width: 900,
        height: 600,
        child: LineupPositionWidget(),
      ),
    );

    expect(container.read(lineUpProvider).currentAgent, isNull);
    expect(find.byType(AgentWidget), findsOneWidget);
    expect(find.byType(Draggable), findsNothing);
  });

  testWidgets('new-lineup current agent and ability reposition on resize',
      (tester) async {
    final container = _createContainer();
    container.read(lineUpProvider.notifier).setAgent(
          PlacedAgent(
            id: 'current-agent',
            type: AgentType.breach,
            position: const Offset(180, 220),
            isAlly: true,
          ),
        );
    container.read(lineUpProvider.notifier).setAbility(
          PlacedAbility(
            id: 'current-ability',
            data: AgentData.agents[AgentType.breach]!.abilities.first,
            position: const Offset(320, 360),
            isAlly: true,
          ),
        );

    await _pumpLineupCanvas(
      tester,
      container: container,
      width: 900,
      height: 600,
    );

    final initialAgentTopLeft = tester.getTopLeft(find.byType(AgentWidget));
    final initialAbilityTopLeft =
        tester.getTopLeft(find.byType(PlacedAbilityWidget));

    CoordinateSystem(playAreaSize: const Size(1200, 800));
    container.read(canvasResizeProvider.notifier).increment();
    await _pumpHarness(
      tester,
      container: container,
      child: const SizedBox(
        width: 1200,
        height: 800,
        child: LineupPositionWidget(),
      ),
    );

    final resizedAgentTopLeft = tester.getTopLeft(find.byType(AgentWidget));
    final resizedAbilityTopLeft =
        tester.getTopLeft(find.byType(PlacedAbilityWidget));

    expect(resizedAgentTopLeft, isNot(initialAgentTopLeft));
    expect(resizedAbilityTopLeft, isNot(initialAbilityTopLeft));

    final coordinateSystem = CoordinateSystem.instance;
    final expectedAgentTopLeft =
        coordinateSystem.coordinateToScreen(const Offset(180, 220));
    final expectedAbilityTopLeft =
        coordinateSystem.coordinateToScreen(const Offset(320, 360));

    expect(resizedAgentTopLeft.dx, closeTo(expectedAgentTopLeft.dx, 0.001));
    expect(resizedAgentTopLeft.dy, closeTo(expectedAgentTopLeft.dy, 0.001));
    expect(resizedAbilityTopLeft.dx, closeTo(expectedAbilityTopLeft.dx, 0.001));
    expect(resizedAbilityTopLeft.dy, closeTo(expectedAbilityTopLeft.dy, 0.001));
  });

  testWidgets('locked add-item preview agent repositions on resize',
      (tester) async {
    final container = _createContainer();
    final group = _breachGroup();
    container.read(lineUpProvider.notifier).addGroup(group);
    container.read(lineUpProvider.notifier).startNewItemForGroup(group.id);

    await _pumpLineupCanvas(
      tester,
      container: container,
      width: 760,
      height: 600,
    );

    final initialAgentTopLeft = tester.getTopLeft(find.byType(AgentWidget));

    CoordinateSystem(playAreaSize: const Size(980, 720));
    container.read(canvasResizeProvider.notifier).increment();
    await _pumpHarness(
      tester,
      container: container,
      child: const SizedBox(
        width: 980,
        height: 720,
        child: LineupPositionWidget(),
      ),
    );

    final resizedAgentTopLeft = tester.getTopLeft(find.byType(AgentWidget));

    expect(resizedAgentTopLeft, isNot(initialAgentTopLeft));

    final expectedAgentTopLeft =
        CoordinateSystem.instance.coordinateToScreen(group.agent.position);
    expect(resizedAgentTopLeft.dx, closeTo(expectedAgentTopLeft.dx, 0.001));
    expect(resizedAgentTopLeft.dy, closeTo(expectedAgentTopLeft.dy, 0.001));
  });

  testWidgets('locked add-item mode rejects dragging a different agent',
      (tester) async {
    final container = _createContainer();
    final group = _breachGroup();
    container.read(lineUpProvider.notifier).addGroup(group);
    container.read(lineUpProvider.notifier).startNewItemForGroup(group.id);
    container
        .read(interactionStateProvider.notifier)
        .update(InteractionState.lineUpPlacing);

    await _pumpHarness(
      tester,
      container: container,
      child: Stack(
        children: [
          const SizedBox(
            width: 760,
            height: 600,
            child: LineupPositionWidget(),
          ),
          Positioned(
            left: 20,
            top: 20,
            child: _AgentDragSource(
              agent: AgentData.agents[AgentType.sova]!,
            ),
          ),
        ],
      ),
    );

    final source = tester.getCenter(find.byType(_AgentDragSource));
    final target = tester.getCenter(find.byType(LineupPositionWidget));
    await tester.dragFrom(source, target - source);
    await tester.pumpAndSettle();

    expect(container.read(lineUpProvider).currentGroupId, group.id);
    expect(container.read(lineUpProvider).currentAgent, isNull);
    expect(
      find.text(
        'You can only add abilities for the selected lineup agent right now.',
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('locked add-item mode accepts matching ability drops',
      (tester) async {
    final container = _createContainer();
    final group = _breachGroup();
    container.read(lineUpProvider.notifier).addGroup(group);
    container.read(lineUpProvider.notifier).startNewItemForGroup(group.id);
    container
        .read(abilityBarProvider.notifier)
        .updateData(AgentData.agents[AgentType.breach]!);
    container
        .read(interactionStateProvider.notifier)
        .update(InteractionState.lineUpPlacing);

    await _pumpHarness(
      tester,
      container: container,
      child: Stack(
        children: [
          const SizedBox(
            width: 760,
            height: 600,
            child: LineupPositionWidget(),
          ),
          Positioned(
            left: 20,
            top: 20,
            child: _AbilityDragSource(
              ability: AgentData.agents[AgentType.breach]!.abilities.first,
            ),
          ),
        ],
      ),
    );

    final source = tester.getCenter(find.byType(_AbilityDragSource));
    final target = tester.getCenter(find.byType(LineupPositionWidget));
    await tester.dragFrom(source, target - source);
    await tester.pumpAndSettle();

    final currentAbility = container.read(lineUpProvider).currentAbility;
    expect(currentAbility, isNotNull);
    expect(currentAbility!.data.type, AgentType.breach);
    expect(currentAbility.lineUpID, group.id);
  });

  test('leaving lineup mode clears the ability bar', () {
    final container = _createContainer();
    final group = _breachGroup();
    container.read(lineUpProvider.notifier).addGroup(group);
    container
        .read(abilityBarProvider.notifier)
        .updateData(AgentData.agents[AgentType.breach]!);
    container.read(lineUpProvider.notifier).startNewItemForGroup(group.id);
    container
        .read(interactionStateProvider.notifier)
        .update(InteractionState.lineUpPlacing);

    container
        .read(interactionStateProvider.notifier)
        .update(InteractionState.navigation);

    expect(container.read(abilityBarProvider), isNull);
    expect(container.read(lineUpProvider).currentGroupId, isNull);
    expect(container.read(lineUpProvider).placementMode, isNull);
  });
}
