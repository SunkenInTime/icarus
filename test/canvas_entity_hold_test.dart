import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/editor_operation_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/placed_widget_builder.dart';
import 'package:icarus/widgets/editor_operation_scope.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const _viewport = Size(1200, 800);

class _TestStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        isSaved: true,
        stratName: null,
        id: 'entity-hold-test',
        storageDirectory: null,
        activePageId: null,
      );

  @override
  void setUnsaved() => state = state.copyWith(isSaved: false);
}

class _TestMapProvider extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: true);
}

void main() {
  setUp(() {
    CoordinateSystem(playAreaSize: _viewport);
    CoordinateSystem.instance.setIsScreenshot(false);
  });

  testWidgets('a press on a real canvas item holds just that item',
      (tester) async {
    tester.view
      ..physicalSize = _viewport
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      strategyProvider.overrideWith(_TestStrategyProvider.new),
      mapProvider.overrideWith(_TestMapProvider.new),
    ]);
    addTearDown(container.dispose);
    container.read(agentProvider.notifier).fromHive([
      PlacedAgent(
          id: 'agent', type: AgentType.sova, position: const Offset(200, 200)),
    ]);
    container.read(lineUpProvider.notifier).fromHive(LineUpGraph(
          origins: [
            LineUpOrigin(
              id: 'origin',
              agent: PlacedAgent(
                id: 'origin-agent',
                type: AgentType.jett,
                position: const Offset(700, 400),
              ),
            ),
          ],
          landings: [
            LineUpLanding(
              id: 'landing',
              ability: PlacedAbility(
                id: 'ability',
                data: AgentData.agents[AgentType.jett]!.abilities.first,
                position: const Offset(900, 500),
              ),
            ),
          ],
          links: [
            LineUpLink(id: 'link', originId: 'origin', landingId: 'landing'),
          ],
        ));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      // As in main.dart: around the navigator, so overlays are inside it.
      child: EditorOperationScope(
          child: ShadApp(
        themeMode: ThemeMode.dark,
        darkTheme: ShadThemeData(
          brightness: Brightness.dark,
          colorScheme: Settings.tacticalVioletTheme,
        ),
        home: Scaffold(
          body: EditorCanvasRegion(
            child: SizedBox.fromSize(
              size: _viewport,
              child: const PlacedWidgetBuilder(),
            ),
          ),
        ),
      )),
    ));
    await tester.pumpAndSettle();
    final agents = find.byType(AgentWidget);
    final plainAgent = tester.getCenter(agents.first);
    final originAgent = tester.getCenter(agents.last);

    final press = await tester.startGesture(plainAgent);
    expect(container.read(editorHeldEntitiesProvider), {'agent'});
    await press.up();
    await tester.pumpAndSettle();
    expect(container.read(editorHeldEntitiesProvider), isEmpty);

    // Empty canvas: nothing held.
    final empty = await tester.startGesture(const Offset(150, 700));
    expect(container.read(editorHeldEntitiesProvider), isEmpty);
    await empty.up();
    await tester.pumpAndSettle();

    // Dragging still reaches the item through its layer, and holds it until
    // the drop commits.
    final drag = await tester.startGesture(plainAgent - const Offset(2, 2),
        kind: PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(65, 45));
    await tester.pumpAndSettle();
    expect(container.read(editorHeldEntitiesProvider), {'agent'});
    await drag.up();
    await tester.pumpAndSettle();
    expect(container.read(agentProvider).single.position,
        isNot(const Offset(200, 200)));
    expect(container.read(editorHeldEntitiesProvider), isEmpty);

    // Last: pressing a lineup origin opens its panel over the canvas.
    final press2 = await tester.startGesture(originAgent);
    expect(container.read(editorHeldEntitiesProvider), {'origin'});
    await press2.up();
    await tester.pumpAndSettle();
  });
}
