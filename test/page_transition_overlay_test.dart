import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/transition_provider.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/role_icon_utility_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';
import 'package:icarus/widgets/mouse_watch.dart';
import 'package:icarus/widgets/page_transition_overlay.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const Color _expectedMutedAllyBgColor = Color.fromARGB(255, 60, 60, 60);

class _FixedMapProvider extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: true);

  @override
  void fromHive(MapValue map, bool isAttack) {}
}

class _DefenseMapProvider extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: false);

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
    expect(find.byType(MouseWatch), findsNothing);

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

    final agentContainer = tester
        .widgetList<Container>(find.byType(Container))
        .singleWhere((widget) => widget.decoration is BoxDecoration);
    final decoration = agentContainer.decoration! as BoxDecoration;
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

  testWidgets('ability vision-cone previews use animated geometry',
      (tester) async {
    final container = _createContainer();
    addTearDown(container.dispose);
    final turret = PlacedAbility(
      id: 'moving-turret',
      data: AgentData.agents[AgentType.killjoy]!.abilities[2],
      position: const Offset(25, 35),
      rotation: 0.3,
      length: 90,
    );
    const animatedPosition = Offset(500, 250);

    await tester.pumpWidget(
      _previewHarness(
        container: container,
        widget: turret,
        coordinatePosition: animatedPosition,
        rotation: 1.1,
        length: 120,
      ),
    );

    final preview = tester.widget<ViewConeWidget>(find.byType(ViewConeWidget));
    final storedAnchor = storedAbilityAnchor(
      ability: turret.data.abilityData!,
      mapScale: 1,
    );
    expect(preview.angle, 100);
    expect(preview.rotation, 1.1);
    expect(preview.length, 120);
    expect(
      preview.worldOrigin,
      animatedPosition +
          CoordinateSystem.instance.virtualOffsetToWorld(storedAnchor),
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

  testWidgets(
      'defense appear and disappear offsets keep view-cone geometry aligned',
      (tester) async {
    final container = _createDefenseContainer();
    addTearDown(container.dispose);
    final coordinateSystem = CoordinateSystem.instance;
    final cone = PlacedUtility(
      id: 'defense-transition-cone',
      type: UtilityType.viewCone90,
      position: const Offset(500, 400),
    )
      ..rotation = 0.6
      ..length = 90;
    const progress = 0.25;
    final directionalOffset = coordinateSystem.scale(28);
    final coneAnchor = coordinateSystem.virtualOffsetToWorld(
      ViewConeWidget.anchorPointVirtual,
    );

    Future<Offset> pumpEntry(PageTransitionEntry entry) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: ShadApp(
            home: Scaffold(
              body: TransitionEntriesLayer(
                entries: [entry],
                agentPaths: const {},
                t: progress,
                direction: PageTransitionDirection.forward,
                agentSize: 40,
                abilitySize: 40,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return tester
          .widget<ViewConeWidget>(find.byType(ViewConeWidget))
          .worldOrigin!;
    }

    final appearOrigin = await pumpEntry(PageTransitionEntry.appear(to: cone));
    final appearTranslation = coordinateSystem.screenWidthToWorld(
      directionalOffset * (1 - progress),
    );
    expect(
      appearOrigin,
      cone.position + Offset(-appearTranslation, 0) + coneAnchor,
    );

    final disappearOrigin = await pumpEntry(
      PageTransitionEntry.disappear(from: cone),
    );
    final disappearTranslation = coordinateSystem.screenWidthToWorld(
      -directionalOffset * progress,
    );
    expect(
      disappearOrigin,
      cone.position + Offset(-disappearTranslation, 0) + coneAnchor,
    );
  });

  testWidgets('temporary rectangle preview applies saved rotation once',
      (tester) async {
    final container = _createContainer();
    addTearDown(container.dispose);
    const rotation = math.pi / 5;
    final rectangle = PlacedUtility(
      id: 'rotated-rectangle',
      type: UtilityType.customRectangle,
      position: const Offset(500, 350),
      customWidth: 8,
      customLength: 16,
      customColorValue: 0xff8b5cf6,
      customOpacityPercent: 40,
    )..rotation = rotation;
    container.read(transitionProvider.notifier).prepare(
      [rectangle],
      startAgentSize: 40,
      startAbilitySize: 40,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ShadApp(
          home: Scaffold(body: TemporaryWidgetBuilder()),
        ),
      ),
    );
    await tester.pump();

    final matchingTransforms =
        tester.widgetList<Transform>(find.byType(Transform)).where((transform) {
      final matrix = transform.transform.storage;
      final renderedRotation = math.atan2(matrix[1], matrix[0]);
      return (renderedRotation - rotation).abs() < 0.0001;
    });
    expect(matchingTransforms, hasLength(1));
  });

  testWidgets('role icons stay upright during page transitions',
      (tester) async {
    final container = _createContainer();
    addTearDown(container.dispose);
    const roleTypes = [
      UtilityType.controller,
      UtilityType.duelist,
      UtilityType.initiator,
      UtilityType.sentinel,
    ];
    final roleIcons = [
      for (var index = 0; index < roleTypes.length; index++)
        PlacedUtility(
          id: 'rotated-${roleTypes[index].name}',
          type: roleTypes[index],
          position: Offset(350 + (index * 80), 350),
        )..rotation = math.pi / 7 + (index * 0.1),
    ];

    for (final roleIcon in roleIcons) {
      expect(PageTransitionEntry.rotationOf(roleIcon), isNull);
    }

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ShadApp(
          home: Scaffold(
            body: TransitionEntriesLayer(
              entries: [
                for (final roleIcon in roleIcons)
                  PageTransitionEntry.appear(to: roleIcon),
              ],
              agentPaths: const {},
              t: 0.5,
              direction: PageTransitionDirection.forward,
              agentSize: 40,
              abilitySize: 40,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(RoleIconUtilityWidget), findsNWidgets(roleTypes.length));
    for (final roleIcon in roleIcons) {
      expect(_hasTransformAtAngle(tester, roleIcon.rotation), isFalse);
    }
  });

  testWidgets('defense temporary role icons stay upright', (tester) async {
    final container = _createDefenseContainer();
    addTearDown(container.dispose);
    final roleIcon = PlacedUtility(
      id: 'defense-role-icon',
      type: UtilityType.sentinel,
      position: const Offset(500, 350),
    );
    container.read(transitionProvider.notifier).prepare(
      [roleIcon],
      startAgentSize: 40,
      startAbilitySize: 40,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ShadApp(
          home: Scaffold(body: TemporaryWidgetBuilder()),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(RoleIconUtilityWidget), findsOneWidget);
    expect(_hasTransformAtAngle(tester, math.pi), isFalse);
  });
}

bool _hasTransformAtAngle(WidgetTester tester, double angle) {
  return tester.widgetList<Transform>(find.byType(Transform)).any((transform) {
    final matrix = transform.transform.storage;
    final renderedRotation = math.atan2(matrix[1], matrix[0]);
    return (renderedRotation - angle).abs() < 0.0001;
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

ProviderContainer _createDefenseContainer() {
  return ProviderContainer(
    overrides: [
      mapProvider.overrideWith(_DefenseMapProvider.new),
    ],
  );
}
