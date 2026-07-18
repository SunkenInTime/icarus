import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';
import 'package:icarus/widgets/page_transition_overlay.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const Color _expectedMutedAllyBgColor = Color.fromARGB(255, 60, 60, 60);

class _FixedMapProvider extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: true);

  @override
  void fromHive(MapValue map, bool isAttack) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
    CoordinateSystem.instance.setIsScreenshot(false);
  });

  Widget buildHarness({
    required ProviderContainer container,
    required PlacedAgent agent,
    double? deadStateProgress,
  }) {
    return UncontrolledProviderScope(
      container: container,
      child: ShadApp(
        home: Scaffold(
          body: PlacedWidgetPreview.build(
            agent,
            1.0,
            deadStateProgress: deadStateProgress,
            agentSize: 40,
            abilitySize: 40,
          ),
        ),
      ),
    );
  }

  testWidgets('dead agents stay in dead state in transition previews',
      (tester) async {
    final container = _createContainer();
    addTearDown(container.dispose);

    final agent = PlacedAgent(
      id: 'dead-agent',
      type: AgentType.jett,
      position: Offset.zero,
      state: AgentState.dead,
    );

    await tester.pumpWidget(buildHarness(container: container, agent: agent));
    await tester.pumpAndSettle();

    expect(find.byType(ColorFiltered), findsOneWidget);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );
    await tester.pump();
  });

  testWidgets('alive agents do not render dead-state styling in previews',
      (tester) async {
    final container = _createContainer();
    addTearDown(container.dispose);

    final agent = PlacedAgent(
      id: 'alive-agent',
      type: AgentType.jett,
      position: Offset.zero,
      state: AgentState.none,
    );

    await tester.pumpWidget(buildHarness(container: container, agent: agent));
    await tester.pumpAndSettle();

    expect(find.byType(ColorFiltered), findsNothing);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );
    await tester.pump();
  });

  testWidgets('partial dead-state progress lerps styling for transition',
      (tester) async {
    final container = _createContainer();
    addTearDown(container.dispose);

    final agent = PlacedAgent(
      id: 'transition-agent',
      type: AgentType.jett,
      position: Offset.zero,
      state: AgentState.dead,
    );

    await tester.pumpWidget(
      buildHarness(
        container: container,
        agent: agent,
        deadStateProgress: 0.5,
      ),
    );
    await tester.pumpAndSettle();

    final ink = tester.widget<Ink>(find.byType(Ink));
    final decoration = ink.decoration! as BoxDecoration;
    expect(
      decoration.color,
      Color.lerp(Settings.allyBGColor, _expectedMutedAllyBgColor, 0.5),
    );

    final opacity = tester.widget<Opacity>(find.byType(Opacity));
    expect(opacity.opacity, greaterThan(0));
    expect(opacity.opacity, lessThan(1));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );
    await tester.pump();
  });

  testWidgets('free view-cone previews raycast from the animated position',
      (tester) async {
    final container = _createContainer();
    addTearDown(container.dispose);
    final cone = PlacedUtility(
      id: 'moving-cone',
      type: UtilityType.viewCone90,
      position: const Offset(10, 20),
      visionElevation: 1.5,
    )
      ..rotation = 0.2
      ..length = 80;
    const animatedPosition = Offset(320, 410);

    await tester.pumpWidget(
      _previewHarness(
        container: container,
        widget: cone,
        coordinatePosition: animatedPosition,
        rotation: 0.75,
        length: 120,
      ),
    );

    final preview = tester.widget<ViewConeWidget>(find.byType(ViewConeWidget));
    expect(preview.id, isNull);
    expect(preview.rotation, 0.75);
    expect(preview.length, 120);
    expect(preview.visionElevation, 1.5);
    expect(
      preview.worldOrigin,
      animatedPosition +
          CoordinateSystem.instance.virtualOffsetToWorld(
            ViewConeWidget.anchorPointVirtual,
          ),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );
    await tester.pump();
  });

  testWidgets('attached view-cone previews raycast from the animated agent',
      (tester) async {
    final container = _createContainer();
    addTearDown(container.dispose);
    final agent = PlacedViewConeAgent(
      id: 'moving-view-cone-agent',
      type: AgentType.jett,
      presetType: UtilityType.viewCone40,
      position: const Offset(25, 35),
      rotation: 0.3,
      length: 90,
      visionElevation: 2,
    );
    const animatedPosition = Offset(500, 250);

    await tester.pumpWidget(
      _previewHarness(
        container: container,
        widget: agent,
        coordinatePosition: animatedPosition,
        rotation: 1.1,
        length: 140,
      ),
    );

    final preview = tester.widget<ViewConeWidget>(find.byType(ViewConeWidget));
    expect(preview.rotation, 1.1);
    expect(preview.length, 140);
    expect(preview.visionElevation, 2);
    expect(
      preview.worldOrigin,
      animatedPosition +
          CoordinateSystem.instance.virtualOffsetToWorld(
            const Offset(20, 20),
          ),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );
    await tester.pump();
  });
}

Widget _previewHarness({
  required ProviderContainer container,
  required PlacedWidget widget,
  required Offset coordinatePosition,
  required double rotation,
  required double length,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: ShadApp(
      home: Scaffold(
        body: PlacedWidgetPreview.build(
          widget,
          1,
          coordinatePosition: coordinatePosition,
          rotation: rotation,
          length: length,
          agentSize: 40,
          abilitySize: 40,
        ),
      ),
    ),
  );
}

ProviderContainer _createContainer() {
  return ProviderContainer(
    overrides: [
      mapProvider.overrideWith(_FixedMapProvider.new),
    ],
  );
}
