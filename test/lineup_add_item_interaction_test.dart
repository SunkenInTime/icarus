import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/ability_bar_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/canvas_resize_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/placed_ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/placed_widget_builder.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/current_line_up_painter.dart';
import 'package:icarus/widgets/line_up_placement_editor.dart';
import 'package:icarus/widgets/line_up_placer.dart';
import 'package:icarus/widgets/lineup_control_buttons.dart';
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

/// How far [editAndDragAbility] drags the ability.
const _editDrag = Offset(-55, 65);

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
    // The placer's copy is display only. The committed origin underneath is
    // draggable, but the canvas ignores pointers while a lineup is placed.
    expect(
      find.descendant(
        of: find.byType(LineupPositionWidget),
        matching: find.byType(Draggable),
      ),
      findsNothing,
    );
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

  testWidgets('placed lineup ends stay put when dragged', (tester) async {
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

    await tester.drag(find.byType(AgentWidget), const Offset(70, 45));
    await tester.drag(
      find.byKey(const ValueKey('lineup-ability-breach-item')),
      const Offset(-55, 65),
    );
    await tester.pumpAndSettle();

    final state = container.read(lineUpProvider);
    expect(
      state.originById('breach-group')!.agent.position,
      group.agent.position,
    );
    expect(
      state.landingById('breach-item')!.ability.position,
      group.items.single.ability.position,
    );
    expect(container.read(actionProvider), isEmpty);
  });

  testWidgets('edit placement moves an end and Save writes it', (tester) async {
    final container = _createContainer();
    final group = _breachGroup();
    container
        .read(lineUpProvider.notifier)
        .fromHive(LineUpGraph.fromLegacyGroups([group]));

    CoordinateSystem(playAreaSize: const Size(900, 600));
    await _pumpHarness(
      tester,
      container: container,
      // The map pans and zooms under the canvas, so a lineup end's drag only
      // wins the pointer once it has moved.
      child: GestureDetector(
        onScaleUpdate: (_) {},
        child: const SizedBox(
          width: 900,
          height: 600,
          child: Stack(
            children: [
              LineUpOverlay(),
              Positioned.fill(child: LineUpPlacementEditor()),
              Align(
                alignment: Alignment.bottomRight,
                child: LineupControlButtons(),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tapAt(
      tester.getCenter(find.byType(AgentWidget)),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit placement'));
    await tester.pumpAndSettle();
    expect(
      container.read(interactionStateProvider),
      InteractionState.lineUpEditing,
    );

    final abilityFinder =
        find.byKey(const ValueKey('lineup-ability-drag-breach-item'));
    final initialAbilityTopLeft = tester.getTopLeft(abilityFinder);
    const abilityDelta = Offset(-55, 65);
    // A real drag arrives as many small moves; the end must stay under the
    // pointer through all of them.
    final gesture = await tester.startGesture(
      tester.getCenter(abilityFinder),
      kind: PointerDeviceKind.mouse,
    );
    for (var step = 0; step < 5; step++) {
      await gesture.moveBy(abilityDelta / 5);
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();

    final expectedPosition = CoordinateSystem.instance
        .screenToCoordinate(initialAbilityTopLeft + abilityDelta);
    // The marker follows the drag; the lineup moves only on Save.
    expect(tester.getTopLeft(abilityFinder).dx,
        closeTo(initialAbilityTopLeft.dx + abilityDelta.dx, 0.001));
    expect(tester.getTopLeft(abilityFinder).dy,
        closeTo(initialAbilityTopLeft.dy + abilityDelta.dy, 0.001));
    expect(
      container
          .read(lineUpProvider)
          .landingById('breach-item')!
          .ability
          .position,
      group.items.single.ability.position,
    );

    await tester.tap(find.byKey(const ValueKey('lineup-edit-save')));
    await tester.pumpAndSettle();

    final landing = container.read(lineUpProvider).landingById('breach-item')!;
    expect(landing.ability.position.dx, closeTo(expectedPosition.dx, 0.001));
    expect(landing.ability.position.dy, closeTo(expectedPosition.dy, 0.001));
    expect(
      container.read(interactionStateProvider),
      InteractionState.navigation,
    );
    expect(container.read(lineUpProvider).edit, isNull);
  });

  testWidgets('opening another page ends a placement edit and says so',
      (tester) async {
    final container = _createContainer();
    final group = _breachGroup();
    container
        .read(lineUpProvider.notifier)
        .fromHive(LineUpGraph.fromLegacyGroups([group]));
    container.read(interactionStateProvider.notifier).editLineUpPlacement(
          container.read(lineUpProvider).links.single.id,
        );

    CoordinateSystem(playAreaSize: const Size(900, 600));
    await _pumpHarness(
      tester,
      container: container,
      child: const SizedBox(
        width: 900,
        height: 600,
        child: Stack(
          children: [
            LineUpOverlay(),
            Positioned.fill(child: LineUpPlacementEditor()),
          ],
        ),
      ),
    );
    await tester.drag(
      find.byKey(const ValueKey('lineup-ability-drag-breach-item')),
      const Offset(-55, 65),
    );
    await tester.pump();

    // A page copied with "+" holds lineups with the same ids.
    container
        .read(lineUpProvider.notifier)
        .fromHive(LineUpGraph.fromLegacyGroups([group]));
    await tester.pumpAndSettle();

    expect(container.read(lineUpProvider).edit, isNull);
    expect(
      container.read(interactionStateProvider),
      InteractionState.navigation,
    );
    expect(
      container
          .read(lineUpProvider)
          .landingById('breach-item')!
          .ability
          .position,
      group.items.single.ability.position,
    );
    expect(
      find.text('The page changed, so the placement edit closed without '
          'saving.'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  /// Opens placement editing on the Breach lineup and drags its ability by
  /// [_editDrag]. Returns the lineup as it was placed.
  Future<LineUpGroup> editAndDragAbility(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    final group = _breachGroup();
    container
        .read(lineUpProvider.notifier)
        .fromHive(LineUpGraph.fromLegacyGroups([group]));
    container.read(interactionStateProvider.notifier).editLineUpPlacement(
          container.read(lineUpProvider).links.single.id,
        );

    CoordinateSystem(playAreaSize: const Size(900, 600));
    await _pumpHarness(
      tester,
      container: container,
      child: const SizedBox(
        width: 900,
        height: 600,
        child: Stack(
          children: [
            LineUpOverlay(),
            Positioned.fill(child: LineUpPlacementEditor()),
            Align(
              alignment: Alignment.bottomRight,
              child: LineupControlButtons(),
            ),
          ],
        ),
      ),
    );
    await tester.drag(
      find.byKey(const ValueKey('lineup-ability-drag-breach-item')),
      _editDrag,
    );
    await tester.pump();
    return group;
  }

  /// The Breach lineup [group] with its ability at [abilityAt], as a newer
  /// copy of the page would bring it.
  LineUpGraph reloaded(LineUpGroup group, {required Offset abilityAt}) {
    final item = group.items.single;
    return LineUpGraph.fromLegacyGroups([
      group.copyWith(items: [
        item.copyWith(ability: item.ability.copyWith(position: abilityAt)),
      ]),
    ]);
  }

  testWidgets('reloading the same page keeps a placement edit and its drag',
      (tester) async {
    final container = _createContainer();
    final group = await editAndDragAbility(tester, container);
    final abilityFinder =
        find.byKey(const ValueKey('lineup-ability-drag-breach-item'));
    final draggedTopLeft = tester.getTopLeft(abilityFinder);
    final draft =
        container.read(lineUpProvider).edit!.movedLandings['breach-item']!;

    // Resolving a cloud conflict reloads the page on screen.
    container.read(lineUpProvider.notifier).fromHive(
          reloaded(group, abilityAt: group.items.single.ability.position),
          samePage: true,
        );
    await tester.pumpAndSettle();

    expect(
      container.read(interactionStateProvider),
      InteractionState.lineUpEditing,
    );
    expect(tester.getTopLeft(abilityFinder), draggedTopLeft);
    expect(find.textContaining('undone'), findsNothing);
    expect(find.textContaining('without saving'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('lineup-edit-save')));
    await tester.pumpAndSettle();
    expect(
      container
          .read(lineUpProvider)
          .landingById('breach-item')!
          .ability
          .position,
      draft,
    );
    expect(container.read(actionProvider), hasLength(1));
  });

  testWidgets('a reload that moved a dragged spot undoes that drag and says so',
      (tester) async {
    final container = _createContainer();
    final group = await editAndDragAbility(tester, container);
    const theirs = Offset(500, 300);

    container.read(lineUpProvider.notifier).fromHive(
          reloaded(group, abilityAt: theirs),
          samePage: true,
        );
    await tester.pumpAndSettle();

    // Still editing, the ability where the cloud has it.
    expect(
      container.read(interactionStateProvider),
      InteractionState.lineUpEditing,
    );
    expect(container.read(lineUpProvider).edit!.movedLandings, isEmpty);
    expect(
      tester.getTopLeft(
          find.byKey(const ValueKey('lineup-ability-drag-breach-item'))),
      screenPositionForWidget(
        widget: container.read(lineUpProvider).landings.single.ability,
        coordinateSystem: CoordinateSystem.instance,
        mapScale: Maps.mapScale[MapValue.bind] ?? 1.0,
        abilitySize: container.read(strategySettingsProvider).abilitySize,
        isAttack: true,
      ),
    );
    expect(
      find.text("The cloud's version changed a spot you dragged, so that "
          'drag was undone.'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('a reload without the lineups being moved ends the edit',
      (tester) async {
    final container = _createContainer();
    await editAndDragAbility(tester, container);

    // "Use cloud" took the lineup away.
    container
        .read(lineUpProvider.notifier)
        .fromHive(LineUpGraph.empty, samePage: true);
    await tester.pumpAndSettle();

    expect(container.read(lineUpProvider).edit, isNull);
    expect(
      container.read(interactionStateProvider),
      InteractionState.navigation,
    );
    expect(
      find.text('The lineups you were moving are no longer on this page, so '
          'the placement edit closed without saving.'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  /// Opens placement editing on [group]'s lineups, without dragging.
  Future<void> openEdit(
    WidgetTester tester,
    ProviderContainer container,
    LineUpGroup group,
  ) async {
    container
        .read(lineUpProvider.notifier)
        .fromHive(LineUpGraph.fromLegacyGroups([group]));
    container.read(interactionStateProvider.notifier).editLineUpPlacement(
          container.read(lineUpProvider).links.first.id,
        );
    CoordinateSystem(playAreaSize: const Size(900, 600));
    await _pumpHarness(
      tester,
      container: container,
      child: const SizedBox(
        width: 900,
        height: 600,
        child: Stack(
          children: [
            LineUpOverlay(),
            Positioned.fill(child: LineUpPlacementEditor()),
          ],
        ),
      ),
    );
  }

  Future<void> moveInSteps(TestGesture gesture, Offset by) async {
    for (var step = 0; step < 4; step++) {
      await gesture.moveBy(by / 4);
    }
  }

  Finder abilityOf(String landingId) =>
      find.byKey(ValueKey('lineup-ability-drag-$landingId'));

  testWidgets('a reload mid-drag that kept the spot lets the drag carry on',
      (tester) async {
    final container = _createContainer();
    final group = _breachGroup();
    await openEdit(tester, container, group);
    final startTopLeft = tester.getTopLeft(abilityOf('breach-item'));

    final gesture = await tester.startGesture(
      tester.getCenter(abilityOf('breach-item')),
      kind: PointerDeviceKind.mouse,
    );
    await moveInSteps(gesture, _editDrag / 2);
    await tester.pump();
    container.read(lineUpProvider.notifier).fromHive(
          reloaded(group, abilityAt: group.items.single.ability.position),
          samePage: true,
        );
    await tester.pump();
    await moveInSteps(gesture, _editDrag / 2);
    await gesture.up();
    await tester.pump();

    final expected =
        CoordinateSystem.instance.screenToCoordinate(startTopLeft + _editDrag);
    final draft =
        container.read(lineUpProvider).edit!.movedLandings['breach-item']!;
    expect(draft.dx, closeTo(expected.dx, 0.001));
    expect(draft.dy, closeTo(expected.dy, 0.001));
  });

  testWidgets('a reload mid-drag that moved the spot stops that drag',
      (tester) async {
    final container = _createContainer();
    final group = _breachGroup();
    await openEdit(tester, container, group);
    const theirs = Offset(500, 300);

    final gesture = await tester.startGesture(
      tester.getCenter(abilityOf('breach-item')),
      kind: PointerDeviceKind.mouse,
    );
    await moveInSteps(gesture, _editDrag / 2);
    await tester.pump();
    container.read(lineUpProvider.notifier).fromHive(
          reloaded(group, abilityAt: theirs),
          samePage: true,
        );
    await tester.pump();
    // The pointer keeps going, but the drag it was making is gone.
    await moveInSteps(gesture, _editDrag / 2);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(container.read(lineUpProvider).edit!.movedLandings, isEmpty);
    expect(
      find.text("The cloud's version changed a spot you dragged, so that "
          'drag was undone.'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'after a reload removes the lineup being dragged, the next drag starts '
      'fresh', (tester) async {
    final container = _createContainer();
    final breach = _breachGroup();
    final first = breach.items.single;
    final second = first.copyWith(
      id: 'breach-item-2',
      ability: first.ability.copyWith(
        id: 'breach-ability-2',
        position: const Offset(520, 200),
      ),
    );
    final group = breach.copyWith(items: [first, second]);
    await openEdit(tester, container, group);

    final gesture = await tester.startGesture(
      tester.getCenter(abilityOf('breach-item')),
      kind: PointerDeviceKind.mouse,
    );
    await moveInSteps(gesture, _editDrag);
    await tester.pump();
    // The cloud's version no longer has the lineup being dragged.
    container.read(lineUpProvider.notifier).fromHive(
          LineUpGraph.fromLegacyGroups([
            group.copyWith(items: [second]),
          ]),
          samePage: true,
        );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(container.read(lineUpProvider).edit!.linkIds, hasLength(1));

    final secondTopLeft = tester.getTopLeft(abilityOf('breach-item-2'));
    await tester.drag(abilityOf('breach-item-2'), const Offset(30, 20));
    await tester.pump();
    final expected = CoordinateSystem.instance
        .screenToCoordinate(secondTopLeft + const Offset(30, 20));
    final draft =
        container.read(lineUpProvider).edit!.movedLandings['breach-item-2']!;
    expect(draft.dx, closeTo(expected.dx, 0.001));
    expect(draft.dy, closeTo(expected.dy, 0.001));
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  for (final cloudTakesFirstDrag in [false, true]) {
    testWidgets(
        'a reload during a second drag of a spot '
        '${cloudTakesFirstDrag ? 'the cloud moved stops it' : 'it kept lets it carry on'}',
        (tester) async {
      final container = _createContainer();
      final group = _breachGroup();
      await openEdit(tester, container, group);
      final startTopLeft = tester.getTopLeft(abilityOf('breach-item'));
      Offset? draft() =>
          container.read(lineUpProvider).edit!.movedLandings['breach-item'];

      await tester.drag(abilityOf('breach-item'), _editDrag);
      await tester.pump();
      final firstDraft = draft()!;
      const second = Offset(40, 30);
      final gesture = await tester.startGesture(
        tester.getCenter(abilityOf('breach-item')),
        kind: PointerDeviceKind.mouse,
      );
      await moveInSteps(gesture, second / 2);
      await tester.pump();
      // The cloud's version has the spot where the user's first drag put
      // it, or where it was saved.
      container.read(lineUpProvider.notifier).fromHive(
            reloaded(
              group,
              abilityAt: cloudTakesFirstDrag
                  ? firstDraft
                  : group.items.single.ability.position,
            ),
            samePage: true,
          );
      await tester.pump();
      await moveInSteps(gesture, second / 2);
      await gesture.up();
      await tester.pumpAndSettle();

      if (cloudTakesFirstDrag) {
        expect(draft(), isNull);
        expect(
          find.text("The cloud's version changed a spot you dragged, so that "
              'drag was undone.'),
          findsOneWidget,
        );
      } else {
        final expected = CoordinateSystem.instance
            .screenToCoordinate(startTopLeft + _editDrag + second);
        expect(draft()!.dx, closeTo(expected.dx, 0.001));
        expect(draft()!.dy, closeTo(expected.dy, 0.001));
      }
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('a lineup a reload removed mid-drag drags again once it is back',
      (tester) async {
    final container = _createContainer();
    final breach = _breachGroup();
    final first = breach.items.single;
    final second = first.copyWith(
      id: 'breach-item-2',
      ability: first.ability.copyWith(
        id: 'breach-ability-2',
        position: const Offset(520, 200),
      ),
    );
    final group = breach.copyWith(items: [first, second]);
    await openEdit(tester, container, group);

    final gesture = await tester.startGesture(
      tester.getCenter(abilityOf('breach-item')),
      kind: PointerDeviceKind.mouse,
    );
    await moveInSteps(gesture, _editDrag);
    await tester.pump();
    container.read(lineUpProvider.notifier).fromHive(
          LineUpGraph.fromLegacyGroups([
            group.copyWith(items: [second]),
          ]),
          samePage: true,
        );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    // A later reload brings it back, joined through the shared agent.
    container.read(lineUpProvider.notifier).fromHive(
          LineUpGraph.fromLegacyGroups([group]),
          samePage: true,
        );
    await tester.pumpAndSettle();
    expect(container.read(lineUpProvider).edit!.linkIds, hasLength(2));

    await tester.drag(abilityOf('breach-item'), const Offset(30, 20));
    await tester.pump();
    expect(
      container.read(lineUpProvider).edit!.movedLandings['breach-item'],
      isNotNull,
    );
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('lineup origin opens its menu on right-click', (tester) async {
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

    await tester.tapAt(
      tester.getCenter(find.byType(AgentWidget)),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add lineup'));
    await tester.pumpAndSettle();

    final placement = container.read(lineUpProvider).placement;
    expect(placement?.pinnedOriginId, group.id);
    expect(placement?.mode, LineUpPlacementMode.fromPinnedOrigin);
    expect(
      container.read(lineUpProvider).originById('breach-group')!.agent.position,
      group.agent.position,
    );
  });

  testWidgets('defense placement edits persist canonical marker positions',
      (tester) async {
    final container = _createContainer();
    final group = _breachGroup();
    container
        .read(lineUpProvider.notifier)
        .fromHive(LineUpGraph.fromLegacyGroups([group]));
    container.read(mapProvider.notifier).switchSide();
    container.read(interactionStateProvider.notifier).editLineUpPlacement(
          container.read(lineUpProvider).links.single.id,
        );

    CoordinateSystem(playAreaSize: const Size(900, 600));
    await _pumpHarness(
      tester,
      container: container,
      child: const SizedBox(
        width: 900,
        height: 600,
        child: Stack(
          children: [
            LineUpOverlay(),
            Positioned.fill(child: LineUpPlacementEditor()),
          ],
        ),
      ),
    );

    final coordinateSystem = CoordinateSystem.instance;
    final settings = container.read(strategySettingsProvider);
    final mapScale = Maps.mapScale[MapValue.bind]!;
    final abilityFinder =
        find.byKey(const ValueKey('lineup-ability-drag-breach-item'));
    final initialAbilityTopLeft = tester.getTopLeft(abilityFinder);
    const abilityDelta = Offset(-55, 65);
    await tester.drag(abilityFinder, abilityDelta);
    await tester.pump();

    final agentFinder =
        find.byKey(const ValueKey('lineup-agent-drag-breach-group'));
    final initialAgentTopLeft = tester.getTopLeft(agentFinder);
    const agentDelta = Offset(70, 45);
    await tester.drag(agentFinder, agentDelta);
    await tester.pump();

    container.read(lineUpProvider.notifier).saveEdit();
    container
        .read(interactionStateProvider.notifier)
        .update(InteractionState.navigation);
    await tester.pump();

    final landing = container.read(lineUpProvider).landingById('breach-item')!;
    final expectedAbilityPosition =
        storedAbilityPositionForRenderedScreenPosition(
      ability: group.items.single.ability.data.abilityData!,
      coordinateSystem: coordinateSystem,
      renderedScreenPosition: initialAbilityTopLeft + abilityDelta,
      mapScale: mapScale,
      abilitySize: settings.abilitySize,
      isAttack: false,
    );
    expect(
      landing.ability.position.dx,
      closeTo(expectedAbilityPosition.dx, 0.001),
    );
    expect(
      landing.ability.position.dy,
      closeTo(expectedAbilityPosition.dy, 0.001),
    );

    final origin = container.read(lineUpProvider).originById('breach-group')!;
    final expectedAgentPosition = storedAgentPositionForRenderedScreenPosition(
      coordinateSystem: coordinateSystem,
      renderedScreenPosition: initialAgentTopLeft + agentDelta,
      agentSize: settings.agentSize,
      isAttack: false,
    );
    expect(origin.agent.position.dx, closeTo(expectedAgentPosition.dx, 0.001));
    expect(origin.agent.position.dy, closeTo(expectedAgentPosition.dy, 0.001));

    container.read(mapProvider.notifier).switchSide();
    await tester.pump();

    // Back on the page, the saved markers sit where the edit left them.
    final placedAgent = find.byKey(const ValueKey('lineup-agent-breach-group'));
    final placedAbility =
        find.byKey(const ValueKey('lineup-ability-breach-item'));

    final attackAgentTopLeft = screenPositionForWidget(
      widget: origin.agent,
      coordinateSystem: coordinateSystem,
      agentSize: settings.agentSize,
      isAttack: true,
    );
    final attackAbilityTopLeft = screenPositionForWidget(
      widget: landing.ability,
      coordinateSystem: coordinateSystem,
      mapScale: mapScale,
      abilitySize: settings.abilitySize,
      isAttack: true,
    );
    expect(
      tester.getTopLeft(placedAgent).dx,
      closeTo(attackAgentTopLeft.dx, 0.001),
    );
    expect(
      tester.getTopLeft(placedAgent).dy,
      closeTo(attackAgentTopLeft.dy, 0.001),
    );
    expect(
      tester.getTopLeft(placedAbility).dx,
      closeTo(attackAbilityTopLeft.dx, 0.001),
    );
    expect(
      tester.getTopLeft(placedAbility).dy,
      closeTo(attackAbilityTopLeft.dy, 0.001),
    );
  });

  testWidgets('pinned origin rejects dragging any agent', (tester) async {
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

  testWidgets('pinned origin accepts matching ability drops', (tester) async {
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
