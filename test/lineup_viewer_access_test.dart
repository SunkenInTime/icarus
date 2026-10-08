import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/strategy_capabilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/collab/lineup_editing_presence_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/widgets/dialogs/lineup_panel_dialog.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/placed_widget_builder.dart';
import 'package:icarus/widgets/line_up_media_carousel.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

class _TestActionProvider extends ActionProvider {
  @override
  List<UserAction> build() => [];
}

class _FixedMapProvider extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.bind, isAttack: true);

  @override
  void fromHive(MapValue map, bool isAttack) {}
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

/// The placed layer as a reader with [role] on a cloud strategy sees it.
Future<ProviderContainer> _pumpCanvas(WidgetTester tester, String role) async {
  final container = ProviderContainer(
    overrides: [
      actionProvider.overrideWith(_TestActionProvider.new),
      mapProvider.overrideWith(_FixedMapProvider.new),
      currentStrategyCapabilitiesProvider.overrideWithValue(
        StrategyCapabilities.fromCloudRole(role),
      ),
    ],
  );
  addTearDown(container.dispose);
  container
      .read(lineUpProvider.notifier)
      .fromHive(LineUpGraph.fromLegacyGroups([_breachGroup()]));

  CoordinateSystem(playAreaSize: const Size(900, 600));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const ToastificationWrapper(
        child: ShadApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 600,
              child: PlacedWidgetBuilder(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

/// The landing's ability icon: the art around it is see-through, and a tap
/// there falls through to the map.
Finder _landingIcon() => find.descendant(
      of: find.byKey(const ValueKey('lineup-ability-breach-item')),
      matching: find.byType(Image),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a viewer opens a lineup landing and sees its media, not edits',
      (tester) async {
    await _pumpCanvas(tester, 'viewer');

    await tester.tap(_landingIcon());
    await tester.pumpAndSettle();

    expect(find.byType(LineUpMediaCarousel), findsOneWidget);
    expect(find.text('Edit'), findsNothing);
    expect(find.byIcon(LucideIcons.trash2), findsNothing);
  });

  testWidgets('a viewer opens a lineup origin without counting as editing it',
      (tester) async {
    final container = await _pumpCanvas(tester, 'viewer');

    await tester.tap(find.byType(AgentWidget));
    await tester.pumpAndSettle();

    expect(find.byType(LineUpPanelDialog), findsOneWidget);
    expect(container.read(openLineUpItemsProvider), isEmpty);

    // A lineup row offers no menu of edits.
    await tester.tapAt(
      tester.getCenter(
        find.byKey(const ValueKey('lineup-panel-row-breach-item')),
      ),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.text('Delete lineup'), findsNothing);
  });

  testWidgets('a viewer cannot move or delete lineup ends', (tester) async {
    final container = await _pumpCanvas(tester, 'viewer');
    final before = container.read(lineUpProvider);

    expect(
      find.byKey(const ValueKey('lineup-ability-drag-breach-item')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('lineup-agent-drag-breach-group')),
      findsNothing,
    );
    await tester.drag(find.byType(AgentWidget), const Offset(70, 45));
    await tester.pumpAndSettle();
    await tester.tapAt(
      tester.getCenter(find.byType(AgentWidget)),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(find.text('Delete origin'), findsNothing);
    expect(container.read(lineUpProvider), same(before));
  });

  testWidgets('an editor keeps the edits on a lineup landing', (tester) async {
    await _pumpCanvas(tester, 'editor');

    expect(
      find.byKey(const ValueKey('lineup-ability-drag-breach-item')),
      findsOneWidget,
    );
    await tester.tap(_landingIcon());
    await tester.pumpAndSettle();

    expect(find.byType(LineUpMediaCarousel), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
  });
}
