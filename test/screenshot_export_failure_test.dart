import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/editor_toolbar.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _FailingSave extends StrategyProvider {
  final pending = Completer<void>();

  @override
  StrategyState build() => StrategyState(
      isSaved: true, stratName: 'Test', id: 'test', storageDirectory: null);

  @override
  Future<void> forceSaveNow(String id) => pending.future;
}

void main() {
  testWidgets(
      'failed screenshot preparation clears the spinner and restores canvas coordinates',
      (tester) async {
    CoordinateSystem(playAreaSize: const Size(1600, 900));
    final saver = _FailingSave();
    final container = ProviderContainer(overrides: [
      strategyProvider.overrideWith(() => saver),
    ]);
    appProviderContainer = container;
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const ShadApp(home: Scaffold(body: EditorToolbar()))));
    await tester.tap(find.byIcon(LucideIcons.camera200));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(CoordinateSystem.instance.isScreenshot, isFalse);
    saver.pending.completeError(StateError('test save failure'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(LucideIcons.camera200), findsOneWidget);
    expect(CoordinateSystem.instance.isScreenshot, isFalse);
    expect(tester.takeException(), isNull);
  });
}
