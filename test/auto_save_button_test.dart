import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/auto_save_notifier.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/widgets/strategy_save_icon_button.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  Future<ProviderContainer> pumpButton(WidgetTester tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ShadApp(home: Scaffold(body: AutoSaveButton())),
      ),
    );
    return container;
  }

  Finder glyph(String key) => find.byKey(ValueKey(key));

  testWidgets('rests on a check when saved and the save glyph when not',
      (tester) async {
    final container = await pumpButton(tester);
    expect(glyph('saved'), findsOneWidget);

    container.read(strategySaveStateProvider.notifier).markDirty();
    await tester.pumpAndSettle();
    expect(glyph('idle'), findsOneWidget);

    container.read(strategySaveStateProvider.notifier).markPersisted();
    await tester.pumpAndSettle();
    expect(glyph('saved'), findsOneWidget);
  });

  testWidgets('does not flash saved over an edit made during the spinner',
      (tester) async {
    final container = await pumpButton(tester);

    container.read(autoSaveProvider.notifier).ping();
    await tester.pump();
    container.read(strategySaveStateProvider.notifier).markDirty();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 200));

    expect(glyph('success'), findsNothing);
    expect(glyph('idle'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
  });
}
