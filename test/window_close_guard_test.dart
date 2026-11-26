import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/strategy/open_seen.dart';
import 'package:icarus/strategy_view.dart';
import 'package:window_manager/window_manager.dart';

import 'editor_on_screen_support.dart';
import 'library_rows/generated_strategies.dart';
import 'library_store/unit_harness.dart';

final class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

final class _HeldSaves extends StrategyProvider {
  Completer<void>? held;

  @override
  Future<bool> flushPendingAutosaveBeforeExit() async => false;

  @override
  Future<void> forceSaveNow(String id) async {
    if (held case final held?) return held.future;
    return super.forceSaveNow(id);
  }
}

List<bool> _preventClose(List<MethodCall> calls) => [
      for (final call in calls)
        if (call.method == 'setPreventClose')
          (call.arguments as Map)['isPreventClose'] as bool,
    ];

Future<void> _stored(String id) async {
  final strategy = generatedStrategy(Optionals.set).copyWith(id: id, name: id);
  await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
      .put(strategy.id, strategy);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final strategies = _HeldSaves();
  final container = ProviderContainer(overrides: [
    authProvider.overrideWith(_SignedOut.new),
    strategyProvider.overrideWith(() => strategies),
  ]);
  appProviderContainer = container;
  container.read(strategyProvider);
  setUpAll(openUnitHive);
  tearDownAll(Hive.close);

  testWidgets(
      'the window keeps asking before it closes while an editor is on '
      'screen, also after an editor that gave way left', (tester) async {
    await tester.runAsync(() async {
      await _stored('first');
      await _stored('second');
    });
    final windowCalls = await pumpLibraryWithEditors(tester, container);
    final navigator = appNavigatorKey.currentState!;

    for (final id in ['first', 'second']) {
      expect(
        StrategyView.open(
          navigator,
          asked: strategies.askedByTheUserNow(),
          initialStrategyId: id,
          initialStrategyName: id,
        ),
        isA<Pushed>(),
      );
    }
    await settleWithDisk(tester);

    expect(container.read(strategyProvider).strategyId, 'second');
    expect(find.byType(StrategyView, skipOffstage: false), findsOneWidget);
    expect(_preventClose(windowCalls), [true]);

    await leaveEditors(tester, container);
    expect(_preventClose(windowCalls), [true, false]);
  });

  testWidgets(
      'a window close whose Save ends after another strategy opened asks '
      'again instead of closing over it', (tester) async {
    await tester.runAsync(() async {
      await _stored('asked-about');
      await _stored('opened-since');
    });
    final windowCalls = await pumpLibraryWithEditors(tester, container);
    expect(
      StrategyView.open(
        appNavigatorKey.currentState!,
        asked: strategies.askedByTheUserNow(),
        initialStrategyId: 'asked-about',
        initialStrategyName: 'asked-about',
      ),
      isA<Pushed>(),
    );
    await settleWithDisk(tester);
    container.read(strategySaveStateProvider.notifier).markDirty();
    final held = strategies.held = Completer<void>();

    (tester.state(find.byType(StrategyView)) as WindowListener).onWindowClose();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(
      await tester.runAsync(() => strategies.openLocal('opened-since',
          asked: strategies.askedByTheUserNow())),
      isA<Changed>(),
    );
    container.read(strategySaveStateProvider.notifier).markDirty();
    windowCalls.clear();
    held.complete();
    strategies.held = null;
    await settleWithDisk(tester);

    expect(container.read(strategyProvider).strategyId, 'opened-since');
    expect(container.read(strategySaveStateProvider).isDirty, isTrue);
    expect(_preventClose(windowCalls), isEmpty);
    expect(windowCalls.map((call) => call.method), ['close']);
    await leaveEditors(tester, container);
  });
}
