import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/delete_area.dart';
import 'package:icarus/widgets/global_shortcuts.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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

/// The editor's delete button inside the app's shortcut layer, with one
/// agent placed.
Future<ProviderContainer> _pumpEditor(WidgetTester tester) async {
  final container = ProviderContainer(
    overrides: [strategyProvider.overrideWith(_LocalStrategy.new)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: ShadApp(
        home: const Scaffold(
          body: Align(alignment: Alignment.topRight, child: DeleteArea()),
        ),
        builder: (context, child) => GlobalShortcuts(child: child!),
      ),
    ),
  );
  container.read(agentProvider.notifier).addAgent(
        PlacedAgent(
          id: 'jett',
          type: AgentType.jett,
          position: const Offset(10, 20),
        ),
      );
  return container;
}

Future<void> _pressUndo(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  setUpAll(() => CoordinateSystem(playAreaSize: const Size(1920, 1080)));

  testWidgets('Ctrl+Z undoes a clear made from the delete menu',
      (tester) async {
    final container = await _pumpEditor(tester);

    await tester.tap(find.byIcon(LucideIcons.trash2));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(LucideIcons.user));
    await tester.pumpAndSettle();
    expect(container.read(agentProvider), isEmpty);
    // A click on an empty part of the page.
    await tester.tapAt(const Offset(200, 500));
    await tester.pumpAndSettle();

    await _pressUndo(tester);
    expect(container.read(agentProvider).map((agent) => agent.id), ['jett']);
  });

  testWidgets('shortcuts fire while the shortcut layer itself has focus',
      (tester) async {
    final container = await _pumpEditor(tester);
    // With the web semantics tree on, a click on an empty part of the page
    // focuses the app's shortcut node itself.
    final shortcutNode = FocusManager.instance.rootScope.descendants
        .singleWhere((node) => node.debugLabel == 'global-shortcuts');
    shortcutNode.requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, shortcutNode);

    await _pressUndo(tester);
    expect(container.read(agentProvider), isEmpty);
  });
}
