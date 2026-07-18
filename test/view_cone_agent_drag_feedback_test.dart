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
import 'package:icarus/widgets/draggable_widgets/agents/placed_view_cone_agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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
}
