import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/widgets/hovered_map_item_name_card.dart';

void main() {
  testWidgets('name changes update one visible card without stacking fades',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(agentProvider.notifier).fromHive([
      PlacedAgent(
        id: 'jett',
        type: AgentType.jett,
        position: Offset.zero,
      ),
      PlacedAgent(
        id: 'sova',
        type: AgentType.sova,
        position: Offset.zero,
      ),
    ]);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: HoveredMapItemNameCard()),
        ),
      ),
    );
    await tester.pump();

    container.read(hoveredDeleteTargetProvider.notifier).state =
        HoveredDeleteTarget.agent(id: 'jett', ownerToken: Object());
    await tester.pump();
    expect(find.text('Jett'), findsOneWidget);

    container.read(hoveredDeleteTargetProvider.notifier).state =
        HoveredDeleteTarget.agent(id: 'sova', ownerToken: Object());
    await tester.pump();

    expect(find.text('Sova'), findsOneWidget);
    expect(find.byType(IntrinsicWidth), findsOneWidget);
    expect(
      find.byKey(const ValueKey('hovered-map-item-name')),
      findsOneWidget,
    );
  });
}
