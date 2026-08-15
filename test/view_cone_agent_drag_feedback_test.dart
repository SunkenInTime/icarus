import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/agents/placed_view_cone_agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'vision_geometry_test_support.dart';

class _FixedMapProvider extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: true);

  @override
  void fromHive(MapValue map, bool isAttack) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('attached view-cone drag feedback skips geometry clipping',
      (tester) async {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
    final container = ProviderContainer(
      overrides: [
        mapProvider.overrideWith(_FixedMapProvider.new),
      ],
    );
    addTearDown(container.dispose);

    final agent = PlacedViewConeAgent(
      id: 'view-cone-agent',
      type: AgentType.sova,
      presetType: UtilityType.viewCone90,
      position: const Offset(200, 300),
      rotation: 0.5,
      length: 75,
    );
    container.read(agentProvider.notifier).fromHive([agent]);

    Widget harness(Widget child) => UncontrolledProviderScope(
          container: container,
          child: ShadApp(
            home: Scaffold(body: Stack(children: [child])),
          ),
        );

    await tester.pumpWidget(
      harness(
        PlacedViewConeAgentWidget(
          agent: agent,
          onDragEnd: (_, __) {},
        ),
      ),
    );

    final placedCone =
        tester.widget<ViewConeWidget>(find.byType(ViewConeWidget));
    expect(placedCone.worldOrigin, isNotNull);

    final draggable = tester.widget<Draggable<PlacedWidget>>(
      find.byWidgetPredicate((widget) => widget is Draggable<PlacedWidget>),
    );
    await tester.pumpWidget(harness(draggable.feedback));

    final feedbackCone =
        tester.widget<ViewConeWidget>(find.byType(ViewConeWidget));
    expect(feedbackCone.worldOrigin, isNull);
  });

  testWidgets('view-cone agent menu hides elevation controls', (tester) async {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
    final container = ProviderContainer(
      overrides: [
        mapProvider.overrideWith(_FixedMapProvider.new),
        viewConeGeometryProvider.overrideWith(
          (ref, map) async => twoLayerAscentGeometry(),
        ),
      ],
    );
    addTearDown(container.dispose);

    final agent = PlacedViewConeAgent(
      id: 'view-cone-agent',
      type: AgentType.sova,
      presetType: UtilityType.viewCone90,
      position: const Offset(200, 300),
      rotation: 0.5,
      length: 75,
    );
    container.read(agentProvider.notifier).fromHive([agent]);
    await container.read(viewConeGeometryProvider(MapValue.ascent).future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ShadApp(
          home: Scaffold(
            body: Stack(
              children: [
                PlacedViewConeAgentWidget(
                  agent: agent,
                  onDragEnd: (_, __) {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tapAt(
      tester.getCenter(find.byType(AgentWidget)),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byType(ShadContextMenuItem), findsOneWidget);
    expect(tester.getSize(find.byType(ShadContextMenuItem)).height, 36);
    final menuItemRect = tester.getRect(find.byType(ShadContextMenuItem));
    final abilityButtons = find.byWidgetPredicate(
      (widget) => widget is Draggable<DraggedAbilityData>,
    );
    final buttonRects = [
      for (final element in abilityButtons.evaluate())
        tester.getRect(
          find.byElementPredicate((candidate) => candidate == element),
        ),
    ];
    final spaces = [
      buttonRects.first.left - menuItemRect.left,
      for (var index = 1; index < buttonRects.length; index++)
        buttonRects[index].left - buttonRects[index - 1].right,
      menuItemRect.right - buttonRects.last.right,
    ];
    for (final space in spaces) {
      expect(space, closeTo(4, 0.1));
    }
    expect(find.text('View elevation'), findsNothing);
    expect(find.text('Vision calibration'), findsNothing);
  });

  testWidgets('free view-cone menu hides elevation controls', (tester) async {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
    final container = ProviderContainer(
      overrides: [
        mapProvider.overrideWith(_FixedMapProvider.new),
        viewConeGeometryProvider.overrideWith(
          (ref, map) async => twoLayerAscentGeometry(),
        ),
      ],
    );
    addTearDown(container.dispose);

    final utility = PlacedUtility(
      id: 'view-cone-utility',
      type: UtilityType.viewCone90,
      position: const Offset(200, 300),
      angle: 60,
    );
    utility.updateRotation(0.5, 75);
    container.read(utilityProvider.notifier).fromHive([utility]);
    await container.read(viewConeGeometryProvider(MapValue.ascent).future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ShadApp(
          home: Scaffold(
            body: ViewConeWidget(
              id: utility.id,
              angle: utility.angle,
              rotation: utility.rotation,
              length: utility.length,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(ShadContextMenuRegion), findsNothing);
    expect(find.text('View elevation'), findsNothing);
    expect(find.text('Vision calibration'), findsNothing);
  });
}
