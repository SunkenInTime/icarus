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
import 'package:icarus/widgets/draggable_widgets/placed_widget_builder.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/current_line_up_painter.dart';
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
      'right-click Add lineup populates ability bar and enters lineup mode',
      (tester) async {
    final container = _createContainer();
    final group = _breachGroup();
    container
        .read(lineUpProvider.notifier)
        .fromHive(LineUpGraph.fromLegacyGroups([group]));

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

    await tester.tap(find.text('Add lineup'));
    await tester.pumpAndSettle();

    expect(container.read(interactionStateProvider),
        InteractionState.lineUpPlacing);
    expect(container.read(abilityBarProvider)?.type, AgentType.breach);
    final placement = container.read(lineUpProvider).placement;
    expect(placement?.pinnedOriginId, group.id);
    expect(placement?.mode, LineUpPlacementMode.fromPinnedOrigin);
  });

  testWidgets('agent quick actions span the width of longer menu rows',
      (tester) async {
    final container = _createContainer();
    final group = _breachGroup();
    container
        .read(lineUpProvider.notifier)
        .fromHive(LineUpGraph.fromLegacyGroups([group]));

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

    final menuItemRect = tester.getRect(
      find.byType(ShadContextMenuItem).first,
    );
    final abilityButtons = find.byWidgetPredicate(
      (widget) => widget is Draggable<DraggedAbilityData>,
    );
    expect(
      abilityButtons,
      findsNWidgets(AgentData.agents[group.agent.type]!.abilities.length),
    );

    final buttonRects = [
      for (final element in abilityButtons.evaluate())
        tester.getRect(
          find.byElementPredicate((candidate) => candidate == element),
        ),
    ];
    final leadingSpace = buttonRects.first.left - menuItemRect.left;
    final trailingSpace = menuItemRect.right - buttonRects.last.right;
    for (var index = 1; index < buttonRects.length; index++) {
      final gap = buttonRects[index].left - buttonRects[index - 1].right;
      expect(gap, closeTo(4, 0.1));
    }
    expect(trailingSpace, closeTo(leadingSpace, 0.1));
    for (final buttonRect in buttonRects) {
      expect(buttonRect.width, 36);
      expect(buttonRect.height, 36);
    }
  });

  testWidgets('pinned origin renders as a non-draggable ringed agent',
      (tester) async {
    final container = _createContainer();
    final group = _breachGroup();
    container
        .read(lineUpProvider.notifier)
        .fromHive(LineUpGraph.fromLegacyGroups([group]));
    container.read(lineUpProvider.notifier).startFromOrigin(group.id);
    container
        .read(interactionStateProvider.notifier)
        .update(InteractionState.lineUpPlacing);

    await _pumpHarness(
      tester,
      container: container,
      child: const SizedBox(
        width: 900,
        height: 600,
        child: Stack(
          children: [
            LineUpOverlay(),
            LineupPositionWidget(),
          ],
        ),
      ),
    );

    expect(container.read(lineUpProvider).placement?.draftAgent, isNull);
    // The overlay's own origin plus the placer's full-opacity copy.
    expect(find.byType(AgentWidget), findsNWidgets(2));
    expect(find.byType(Draggable), findsNothing);
  });

  testWidgets('new-lineup current agent and ability reposition on resize',
      (tester) async {
    final container = _createContainer();
    container.read(lineUpProvider.notifier).startFresh();
    container.read(lineUpProvider.notifier).setDraftAgent(
          PlacedAgent(
            id: 'current-agent',
            type: AgentType.breach,
            position: const Offset(180, 220),
            isAlly: true,
          ),
        );
    container.read(lineUpProvider.notifier).setDraftAbility(
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

  testWidgets('persistent lineup overlay repositions and rescales on resize',
      (tester) async {
    final container = _createContainer();
    final group = _breachGroup();
    container
        .read(lineUpProvider.notifier)
        .fromHive(LineUpGraph.fromLegacyGroups([group]));

    CoordinateSystem(playAreaSize: const Size(900, 600));
    await _pumpHarness(
      tester,
      container: container,
      child: const SizedBox(
        width: 900,
        height: 600,
        child: LineUpOverlay(),
      ),
    );

    final agentFinder = find.byType(AgentWidget);
    final initialAgentTopLeft = tester.getTopLeft(agentFinder);
    final initialAgentSize = tester.getSize(agentFinder);
    final initialAbilityTopLeft = tester
        .getTopLeft(find.byKey(const ValueKey('lineup-ability-breach-item')));
    final initialAbilitySize = tester
        .getSize(find.byKey(const ValueKey('lineup-ability-breach-item')));

    CoordinateSystem(playAreaSize: const Size(1200, 800));
    container.read(canvasResizeProvider.notifier).increment();
    await tester.pump();

    final resizedAgentTopLeft = tester.getTopLeft(agentFinder);
    final resizedAgentSize = tester.getSize(agentFinder);
    final resizedAbilityTopLeft = tester
        .getTopLeft(find.byKey(const ValueKey('lineup-ability-breach-item')));
    final resizedAbilitySize = tester
        .getSize(find.byKey(const ValueKey('lineup-ability-breach-item')));

    expect(resizedAgentTopLeft, isNot(initialAgentTopLeft));
    expect(resizedAbilityTopLeft, isNot(initialAbilityTopLeft));
    expect(resizedAgentSize, isNot(initialAgentSize));
    expect(resizedAbilitySize, isNot(initialAbilitySize));

    final coordinateSystem = CoordinateSystem.instance;
    final expectedAgentTopLeft =
        coordinateSystem.coordinateToScreen(group.agent.position);
    final expectedAbilityTopLeft = coordinateSystem
        .coordinateToScreen(group.items.single.ability.position);

    expect(resizedAgentTopLeft.dx, closeTo(expectedAgentTopLeft.dx, 0.001));
    expect(resizedAgentTopLeft.dy, closeTo(expectedAgentTopLeft.dy, 0.001));
    expect(resizedAbilityTopLeft.dx, closeTo(expectedAbilityTopLeft.dx, 0.001));
    expect(resizedAbilityTopLeft.dy, closeTo(expectedAbilityTopLeft.dy, 0.001));
  });

  testWidgets('pinned origin rejects dragging any agent',
      (tester) async {
    final container = _createContainer();
    final group = _breachGroup();
    container
        .read(lineUpProvider.notifier)
        .fromHive(LineUpGraph.fromLegacyGroups([group]));
    container.read(lineUpProvider.notifier).startFromOrigin(group.id);
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

    final placement = container.read(lineUpProvider).placement;
    expect(placement?.pinnedOriginId, group.id);
    expect(placement?.draftAgent, isNull);
    expect(
      find.text('The origin is pinned. Drag an ability instead.'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('pinned origin accepts matching ability drops',
      (tester) async {
    final container = _createContainer();
    final group = _breachGroup();
    container
        .read(lineUpProvider.notifier)
        .fromHive(LineUpGraph.fromLegacyGroups([group]));
    container.read(lineUpProvider.notifier).startFromOrigin(group.id);
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

    final draftAbility = container.read(lineUpProvider).placement?.draftAbility;
    expect(draftAbility, isNotNull);
    expect(draftAbility!.data.type, AgentType.breach);
    expect(container.read(lineUpProvider).placement?.isComplete, isTrue);
  });

  testWidgets('repositioning a draft end publishes its hover while dragging',
      (tester) async {
    final container = _createContainer();
    container.read(lineUpProvider.notifier).startFresh();
    container.read(lineUpProvider.notifier).setDraftAgent(
          PlacedAgent(
            id: 'current-agent',
            type: AgentType.breach,
            position: const Offset(180, 220),
            isAlly: true,
          ),
        );
    container.read(lineUpProvider.notifier).setDraftAbility(
          PlacedAbility(
            id: 'current-ability',
            data: AgentData.agents[AgentType.breach]!.abilities.first,
            position: const Offset(320, 360),
            isAlly: true,
          ),
        );
    container
        .read(interactionStateProvider.notifier)
        .update(InteractionState.lineUpPlacing);

    await _pumpLineupCanvas(
      tester,
      container: container,
      width: 900,
      height: 600,
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(AgentWidget)),
    );
    await tester.pump();
    for (var step = 0; step < 4; step++) {
      await gesture.moveBy(const Offset(30, -15));
      await tester.pump();
    }

    final hover = container.read(lineUpDragHoverProvider);
    expect(hover, isNotNull);
    expect(hover!.end, LineUpEnd.origin);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(container.read(lineUpDragHoverProvider), isNull);
    expect(
      container.read(lineUpProvider).placement?.draftAgent?.position,
      isNot(const Offset(180, 220)),
    );
  });

  test('leaving lineup mode clears the ability bar', () {
    final container = _createContainer();
    final group = _breachGroup();
    container
        .read(lineUpProvider.notifier)
        .fromHive(LineUpGraph.fromLegacyGroups([group]));
    container
        .read(abilityBarProvider.notifier)
        .updateData(AgentData.agents[AgentType.breach]!);
    container.read(lineUpProvider.notifier).startFromOrigin(group.id);
    container
        .read(interactionStateProvider.notifier)
        .update(InteractionState.lineUpPlacing);

    container
        .read(interactionStateProvider.notifier)
        .update(InteractionState.navigation);

    expect(container.read(abilityBarProvider), isNull);
    expect(container.read(lineUpProvider).placement, isNull);
  });
}
