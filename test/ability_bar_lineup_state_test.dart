import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_bar_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/widgets/sidebar_widgets/ability_bar.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _FixedMapProvider extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.bind, isAttack: true);

  @override
  void fromHive(MapValue map, bool isAttack) {}
}

ProviderContainer _createContainer() {
  final container = ProviderContainer(
    overrides: [mapProvider.overrideWith(_FixedMapProvider.new)],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pumpHarness(
  WidgetTester tester, {
  required ProviderContainer container,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const ShadApp(
        home: Scaffold(body: Center(child: AbiilityBar())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

LineUpGroup _sovaGroup() {
  return LineUpGroup(
    id: 'sova-group',
    agent: PlacedAgent(
      id: 'sova-agent',
      type: AgentType.sova,
      position: const Offset(180, 220),
      isAlly: true,
    ),
    items: [
      LineUpItem(
        id: 'sova-item',
        ability: PlacedAbility(
          id: 'sova-ability',
          data: AgentData.agents[AgentType.sova]!.abilities.first,
          position: const Offset(320, 360),
          isAlly: true,
        ),
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  testWidgets('pinned landing dims and disables the ability bar',
      (tester) async {
    final container = _createContainer();
    final group = _sovaGroup();
    final notifier = container.read(lineUpProvider.notifier);
    notifier.fromHive(LineUpGraph.fromLegacyGroups([group]));
    container
        .read(abilityBarProvider.notifier)
        .updateData(AgentData.agents[AgentType.sova]!);
    notifier.startToLanding(group.items.single.id);
    container
        .read(interactionStateProvider.notifier)
        .update(InteractionState.lineUpPlacing);

    await _pumpHarness(tester, container: container);

    expect(find.byKey(const ValueKey('ability-bar-disabled')), findsOneWidget);
  });

  testWidgets('pinned origin keeps the ability bar live', (tester) async {
    final container = _createContainer();
    final group = _sovaGroup();
    final notifier = container.read(lineUpProvider.notifier);
    notifier.fromHive(LineUpGraph.fromLegacyGroups([group]));
    container
        .read(abilityBarProvider.notifier)
        .updateData(AgentData.agents[AgentType.sova]!);
    notifier.startFromOrigin(group.id);
    container
        .read(interactionStateProvider.notifier)
        .update(InteractionState.lineUpPlacing);

    await _pumpHarness(tester, container: container);

    expect(find.byKey(const ValueKey('ability-bar-disabled')), findsNothing);
  });
}
