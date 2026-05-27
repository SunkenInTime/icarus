import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/widgets/page_transition_overlay.dart';

const Color _expectedMutedAllyBgColor = Color.fromARGB(255, 60, 60, 60);

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
      child: MaterialApp(
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
    final container = ProviderContainer();
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
    final container = ProviderContainer();
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
    final container = ProviderContainer();
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
}
