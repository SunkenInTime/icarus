import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/delete_capture.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/placed_widget_builder.dart';
import 'package:icarus/widgets/global_shortcuts.dart';
import 'package:icarus/widgets/line_up_placer.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const _viewport = Size(1200, 800);

class _LocalStrategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        strategyId: 'local-strategy',
        strategyName: null,
        source: StrategySource.local,
        storageDirectory: null,
        isOpen: true,
      );

  @override
  void setUnsaved() {}
}

class _AttackMap extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: true);
}

PlacedAgent _placed() => PlacedAgent(
      id: 'jett',
      type: AgentType.jett,
      position: const Offset(600, 400),
    );

ProviderContainer _container(WidgetTester tester) {
  tester.view
    ..physicalSize = _viewport
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      strategyProvider.overrideWith(_LocalStrategy.new),
      mapProvider.overrideWith(_AttackMap.new),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });
  return container;
}

/// [child] in a box short of the window, so the capture behind it, which
/// takes what is dropped off the map, shows along the bottom.
Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget child,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: ShadApp(
        home: Scaffold(
          body: Stack(
            children: [
              const Positioned.fill(child: DeleteCapture()),
              Positioned(
                left: 0,
                top: 0,
                width: _viewport.width,
                height: _viewport.height - 100,
                child: child,
              ),
            ],
          ),
        ),
        builder: (context, child) => GlobalShortcuts(child: child!),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The page as Create Lineup leaves it: [agent] placed, and a draft that
/// shares its id.
Future<void> _pumpDraftOf(
  WidgetTester tester,
  ProviderContainer container,
  PlacedAgent agent,
) async {
  container.read(agentProvider.notifier).fromHive([agent]);
  final lineUps = container.read(lineUpProvider.notifier);
  lineUps.startFresh();
  lineUps.setDraftAgent(agent);
  container
      .read(interactionStateProvider.notifier)
      .update(InteractionState.lineUpPlacing);
  await _pump(tester, container, const LineupPositionWidget());
}

Future<void> _hoverAndPressDeleteShortcut(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: tester.getCenter(find.byType(AgentWidget)));
  addTearDown(mouse.removePointer);
  await tester.pumpAndSettle();
  await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
  await tester.pumpAndSettle();
}

Future<void> _dropOffTheMap(WidgetTester tester) async {
  final drag = await tester.startGesture(
    tester.getCenter(find.byType(AgentWidget)),
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump();
  await drag.moveBy(const Offset(0, 20));
  await tester.pump();
  await drag.moveTo(const Offset(600, 760));
  await tester.pump();
  await drag.up();
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => CoordinateSystem(playAreaSize: const Size(1200, 700)));

  testWidgets('the delete shortcut on a hovered agent removes it',
      (tester) async {
    final container = _container(tester);
    container.read(agentProvider.notifier).fromHive([_placed()]);
    await _pump(tester, container, const PlacedWidgetBuilder());

    await _hoverAndPressDeleteShortcut(tester);

    expect(container.read(agentProvider), isEmpty);
  });

  testWidgets('the delete shortcut on a draft leaves the placed agent',
      (tester) async {
    final container = _container(tester);
    await _pumpDraftOf(tester, container, _placed());

    await _hoverAndPressDeleteShortcut(tester);

    expect(container.read(agentProvider).map((agent) => agent.id), ['jett']);
    expect(container.read(lineUpProvider).placement?.draftAgent?.id, 'jett');
  });

  testWidgets('a draft dropped off the map leaves the placed agent',
      (tester) async {
    final container = _container(tester);
    await _pumpDraftOf(tester, container, _placed());

    await _dropOffTheMap(tester);

    final placed = container.read(agentProvider).single;
    expect(placed.id, 'jett');
    expect(placed.position, const Offset(600, 400));
  });

  testWidgets('moving a draft and cancelling leaves the placed agent in place',
      (tester) async {
    final container = _container(tester);
    await _pumpDraftOf(tester, container, _placed());

    container
        .read(lineUpProvider.notifier)
        .updateDraftAgentPosition(const Offset(100, 100));
    expect(container.read(lineUpProvider).placement?.draftAgent?.position,
        const Offset(100, 100));
    expect(
        container.read(agentProvider).single.position, const Offset(600, 400));

    container
        .read(interactionStateProvider.notifier)
        .update(InteractionState.navigation);
    expect(
        container.read(agentProvider).single.position, const Offset(600, 400));
  });
}
