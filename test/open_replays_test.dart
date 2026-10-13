import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/providers/in_app_debug_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/replay_library_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/replay/replay_files.dart';
import 'package:icarus/replay_view.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/ica_drop_target.dart';
import 'package:icarus/widgets/mouse_navigation.dart';
import 'package:icarus/widgets/replay/open_replays.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart';

class _OpenStrategy extends StrategyProvider {
  _OpenStrategy(this.initial);

  final StrategyState initial;

  @override
  StrategyState build() => initial;

  /// Autosave is off, so leaving has to ask.
  @override
  Future<bool> flushPendingAutosaveBeforeExit() async => false;
}

const _noStrategy = StrategyState(
  strategyId: null,
  strategyName: null,
  source: null,
  storageDirectory: null,
  isOpen: false,
);

const _dirtyStrategy = StrategyState(
  strategyId: 'strategy-a',
  strategyName: 'Strategy A',
  source: StrategySource.local,
  storageDirectory: null,
  isOpen: true,
);

/// Sends what desktop_drop's Windows plugin sends for a drop at [at].
Future<void> _drop(WidgetTester tester, List<String> paths, Offset at) async {
  final messenger = tester.binding.defaultBinaryMessenger;
  Future<void> send(String method, Object arguments) =>
      messenger.handlePlatformMessage(
        'desktop_drop',
        const StandardMethodCodec()
            .encodeMethodCall(MethodCall(method, arguments)),
        (_) {},
      );
  final dpr = tester.view.devicePixelRatio;
  final position = <double>[at.dx * dpr, at.dy * dpr];
  await send('entered', position);
  await send('updated', position);
  await send('performOperation', paths);
}

void main() {
  late Directory temp;
  late Directory support;

  setUpAll(() {
    // Where AppErrorReporter keeps what it reports.
    appProviderContainer = ProviderContainer();
  });

  setUp(() async {
    appProviderContainer.read(inAppDebugProvider.notifier).clearLogs();
    temp = await Directory.systemTemp.createTemp('open-replays-test-');
    support = await Directory(p.join(temp.path, 'support')).create();
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<String> replayFile(String name) async {
    final file = File(p.join(temp.path, name));
    await file.writeAsString('not a real replay');
    return file.path;
  }

  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    required StrategyState strategy,
  }) async {
    final container = ProviderContainer(
      overrides: [
        strategyProvider.overrideWith(() => _OpenStrategy(strategy)),
        replayFilesProvider.overrideWithValue(
          ReplayFiles(
            supportDirectory: () async => support,
            valorantDemosPath: null,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ShadApp(
          navigatorKey: appNavigatorKey,
          navigatorObservers: [mouseNavigationRouteObserver],
          builder: (context, child) => ReplayWindowDropTarget(child: child!),
          // My Library's drop target, which takes .ica files.
          home: const Scaffold(body: IcaDropTarget(child: SizedBox.expand())),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  Future<List<String>> keptReplays() async {
    final directory = Directory(p.join(support.path, 'replays'));
    if (!await directory.exists()) return const [];
    return [
      for (final entity in directory.listSync())
        if (entity is File) p.basename(entity.path),
    ]..sort();
  }

  testWidgets('replays dropped on My Library land on the Replays tab',
      (tester) async {
    final container = await pumpApp(tester, strategy: _noStrategy);
    final paths = [
      await tester.runAsync(() => replayFile('a.vrf')),
      await tester.runAsync(() => replayFile('b.vrf')),
    ].cast<String>();

    // The copy is real file IO, so it runs on the real clock.
    await tester.runAsync(() async {
      await _drop(tester, paths, const Offset(400, 300));
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await tester.pumpAndSettle();

    expect(await tester.runAsync(keptReplays), ['a.vrf', 'b.vrf']);
    expect(container.read(replaysTabOpenProvider), isTrue);
    // Several replays open no viewer.
    expect(find.byType(ReplayView), findsNothing);
    // My Library's .ica import left them alone instead of calling them
    // unsupported files.
    expect(appProviderContainer.read(inAppDebugProvider), isEmpty);
  });

  testWidgets('staying in the editor with unsaved work adds nothing',
      (tester) async {
    final container = await pumpApp(tester, strategy: _dirtyStrategy);
    container.read(strategySaveStateProvider.notifier).markDirty();
    final path = (await tester.runAsync(() => replayFile('a.vrf')))!;

    await tester.runAsync(() async {
      await _drop(tester, [path], const Offset(400, 300));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(find.text('Save changes?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.runAsync(() => Future<void>.delayed(
          const Duration(milliseconds: 300),
        ));
    await tester.pumpAndSettle();

    expect(await tester.runAsync(keptReplays), isEmpty);
    expect(container.read(replaysTabOpenProvider), isFalse);
    expect(container.read(strategyProvider).strategyName, 'Strategy A');
  });
}
