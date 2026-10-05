import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  testWidgets('strategy actions expose a named tap action', (tester) async {
    var pressed = false;
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      ShadApp(
        home: Scaffold(
          body: StrategyTileActionsButton(
            strategyName: 'A Split',
            onPressed: () => pressed = true,
          ),
        ),
      ),
    );

    final finder = find.bySemanticsLabel('More actions for A Split');
    expect(
      tester.getSemantics(finder),
      matchesSemantics(
        label: 'More actions for A Split',
        isButton: true,
        hasTapAction: true,
      ),
    );
    tester.semantics.tap(find.semantics.byLabel('More actions for A Split'));
    await tester.pump();
    expect(pressed, isTrue);
    semantics.dispose();
  });

  testWidgets('strategy menu actions expose named tap actions', (tester) async {
    var pressed = false;
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      ShadApp(
        home: Scaffold(
          body: StrategyTileMenuActionSemantics(
            label: 'Export A Split',
            enabled: true,
            onPressed: () => pressed = true,
            child: const Text('Export'),
          ),
        ),
      ),
    );

    final finder = find.bySemanticsLabel('Export A Split');
    expect(
      tester.getSemantics(finder),
      matchesSemantics(
        label: 'Export A Split',
        isButton: true,
        isEnabled: true,
        hasEnabledState: true,
        hasTapAction: true,
      ),
    );
    tester.semantics.tap(find.semantics.byLabel('Export A Split'));
    await tester.pump();
    expect(pressed, isTrue);
    semantics.dispose();
  });
}
