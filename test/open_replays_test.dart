import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/routes.dart';
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
import 'package:toastification/toastification.dart';

class _OpenStrategy extends StrategyProvider {
  _OpenStrategy(this.initial);

  final StrategyState initial;

  @override
  StrategyState build() => initial;

  /// Autosave is off, so leaving has to ask.
  @override
  Future<bool> flushPendingAutosaveBeforeExit() async => false;

  @override
  void cancelPendingSave() {}

  @override
  Future<void> clearCurrentStrategy() async => state = _noStrategy;
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

/// Sends what desktop_drop's plugin sends for a drop at [at].
Future<void> _drop(WidgetTester tester, List<String> paths, Offset at) async {
  final messenger = tester.binding.defaultBinaryMessenger;
  Future<void> send(String method, Object arguments) =>
      messenger.handlePlatformMessage(
        'desktop_drop',
        const StandardMethodCodec()
            .encodeMethodCall(MethodCall(method, arguments)),
        (_) {},
      );
  // The plugin reports physical pixels on Windows and logical ones elsewhere.
  final scale = Platform.isWindows ? tester.view.devicePixelRatio : 1.0;
  final position = <double>[at.dx * scale, at.dy * scale];
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
    // Leaving the editor resets the agent filter, which reads favorites.
    Hive.init(p.join(temp.path, 'hive'));
    await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
  });

  tearDown(() async {
    await Hive.close();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<String> replayFile(String name) async {
    final file = File(p.join(temp.path, name));
    await file.writeAsString('not a real replay');
    return file.path;
  }

  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    StrategyState strategy = _noStrategy,
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
        child: ToastificationWrapper(
          child: ShadApp(
            navigatorKey: appNavigatorKey,
            navigatorObservers: [mouseNavigationRouteObserver],
            builder: (context, child) => ReplayWindowDropTarget(child: child!),
            // My Library's drop target, which takes .ica files.
            home: const Scaffold(
              body: IcaDropTarget(child: SizedBox.expand()),
            ),
          ),
        ),
      ),
    );
    if (strategy.strategyName != null) {
      appNavigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: Routes.strategyView),
          builder: (_) => const Scaffold(body: Text('editor')),
        ),
      );
    }
    await tester.pumpAndSettle();
    return container;
  }

  /// Drops [names] (files that aren't real replays) and lets the copies,
  /// which are real file IO, run on the real clock.
  Future<void> dropFiles(WidgetTester tester, List<String> names) async {
    await tester.runAsync(() async {
      final paths = [for (final name in names) await replayFile(name)];
      await _drop(tester, paths, const Offset(400, 300));
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await tester.pumpAndSettle();
  }

  /// The drop's work started on the real clock, so what it awaits resumes
  /// there: let the dialog close, then let the open finish.
  Future<void> settle(WidgetTester tester) async {
    for (var round = 0; round < 2; round++) {
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
    }
    await tester.pumpAndSettle();
  }

  Future<List<String>> keptReplays() async {
    final directory = Directory(p.join(support.path, 'replays'));
    if (!await directory.exists()) return const [];
    return [
      for (final entity in directory.listSync())
        if (entity is File) p.basename(entity.path),
    ]..sort();
  }

  /// The reason a tile gives for a replay it can't open.
  String reasonFor(ProviderContainer container, String name) {
    final listing = container
        .read(replayLibraryProvider)
        .requireValue
        .firstWhere((listing) => p.basename(listing.file.path) == name);
    return listing.error!.message;
  }

  /// Lets the toasts close so no timer outlives the test.
  Future<void> closeToasts(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 5));

  testWidgets('one unreadable replay lands on the tab with its reason',
      (tester) async {
    final container = await pumpApp(tester);

    await dropFiles(tester, ['a.vrf']);

    expect(await tester.runAsync(keptReplays), ['a.vrf']);
    expect(container.read(replaysTabOpenProvider), isTrue);
    expect(find.byType(ReplayView), findsNothing);
    expect(find.text(reasonFor(container, 'a.vrf')), findsOneWidget);
    await closeToasts(tester);
  });

  testWidgets('several replays dropped on My Library land on the tab',
      (tester) async {
    final container = await pumpApp(tester);

    await dropFiles(tester, ['a.vrf', 'b.vrf']);

    expect(await tester.runAsync(keptReplays), ['a.vrf', 'b.vrf']);
    expect(container.read(replaysTabOpenProvider), isTrue);
    // Several replays open nothing, so nothing explains why one can't open.
    expect(find.text(reasonFor(container, 'a.vrf')), findsNothing);
    // My Library's .ica import left them alone instead of calling them
    // unsupported files.
    expect(appProviderContainer.read(inAppDebugProvider), isEmpty);
    await closeToasts(tester);
  });

  testWidgets('staying in the editor keeps it open', (tester) async {
    final container = await pumpApp(tester, strategy: _dirtyStrategy);
    container.read(strategySaveStateProvider.notifier).markDirty();

    await dropFiles(tester, ['a.vrf']);
    expect(find.text('Save changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(find.text('Save changes?'), findsNothing);

    expect(find.text('editor'), findsOneWidget);
    expect(container.read(strategyProvider).strategyName, 'Strategy A');
    expect(container.read(replaysTabOpenProvider), isFalse);
    // The replay is added either way, as Add Replay would.
    expect(await tester.runAsync(keptReplays), ['a.vrf']);
    await closeToasts(tester);
  });

  testWidgets('leaving the editor without saving opens the Replays tab',
      (tester) async {
    final container = await pumpApp(tester, strategy: _dirtyStrategy);
    container.read(strategySaveStateProvider.notifier).markDirty();

    await dropFiles(tester, ['a.vrf']);
    await tester.tap(find.text("Don't save"));
    await settle(tester);
    expect(find.text('Save changes?'), findsNothing);

    expect(container.read(strategyProvider).strategyName, isNull);
    expect(container.read(replaysTabOpenProvider), isTrue);
    expect(find.text('editor'), findsNothing);
    await closeToasts(tester);
  });
}
