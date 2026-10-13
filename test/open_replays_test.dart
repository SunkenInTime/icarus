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
import 'package:icarus/replay/replay_decoder.dart';
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

/// Reads the header these tests write: `patch 13.06` is a replay from a
/// patch Icarus can't read yet, anything else isn't a replay. None can be
/// watched, so the viewer, which needs the native decoder, never opens; the
/// one-replay tests see it chosen through the reason it gives instead.
Future<ReplayProbe> _probe(String path) async {
  final text = await File(path).readAsString();
  if (!text.startsWith('patch ')) {
    throw const ReplayDecodeException('notAReplay', 'Not a replay.');
  }
  final patch = text.substring('patch '.length);
  return ReplayProbe(
    matchId: p.basenameWithoutExtension(path),
    mapPath: '/Game/Maps/Ascent/Ascent',
    build: '++Ares-Core+release-$patch',
    durationMs: 1000,
    supported: false,
    decoderVersion: 'test',
    agentIds: const [],
  );
}

void main() {
  late Directory temp;
  late Directory support;

  /// Texts seen on screen while [settle] ran. A toast can close before the
  /// test looks.
  final seen = <String>{};
  const watched = [
    "Replays from patch 13.06 can't be read yet. "
        'An Icarus update will add them.',
    "a.vrf isn't a replay Icarus can read.",
  ];

  setUpAll(() {
    // Where AppErrorReporter keeps what it reports.
    appProviderContainer = ProviderContainer();
  });

  setUp(() async {
    seen.clear();
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
        replayProbeProvider.overrideWithValue(_probe),
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

  /// The drop's work is real file IO, which only finishes on the real clock,
  /// and its continuations and the replay list's rebuilds run on the test's:
  /// give it both, in turns, long enough for every step of an add and an
  /// open.
  Future<void> settle(WidgetTester tester) async {
    for (var round = 0; round < 200; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      for (final text in watched) {
        if (find.text(text).evaluate().isNotEmpty) seen.add(text);
      }
    }
  }

  /// Drops files named after [contents]' keys, holding their values.
  Future<void> dropFiles(
    WidgetTester tester,
    Map<String, String> contents,
  ) async {
    final paths = [
      for (final name in contents.keys) p.join(temp.path, name),
    ];
    await tester.runAsync(() async {
      for (final (index, text) in contents.values.indexed) {
        await File(paths[index]).writeAsString(text);
      }
    });
    // Dropped on the test's clock, so the toasts' timers are too.
    await _drop(tester, paths, const Offset(400, 300));
    await settle(tester);
  }

  Future<List<String>> keptReplays() async {
    final directory = Directory(p.join(support.path, 'replays'));
    if (!await directory.exists()) return const [];
    return [
      for (final entity in directory.listSync())
        if (entity is File) p.basename(entity.path),
    ]..sort();
  }

  /// Lets the toasts close so no timer outlives the test.
  Future<void> closeToasts(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 5));

  final patchReason = watched[0];
  final notAReplay = watched[1];

  testWidgets('one replay from an unreadable patch says why instead',
      (tester) async {
    final container = await pumpApp(tester);

    await dropFiles(tester, {'a.vrf': 'patch 13.06'});

    expect(await tester.runAsync(keptReplays), ['a.vrf']);
    expect(container.read(replaysTabOpenProvider), isTrue);
    expect(find.byType(ReplayView), findsNothing);
    expect(seen, contains(patchReason));
    await closeToasts(tester);
  });

  testWidgets('a file that is not a replay stays where the user is',
      (tester) async {
    final container = await pumpApp(tester);

    await dropFiles(tester, {'a.vrf': 'not a replay'});

    expect(await tester.runAsync(keptReplays), isEmpty);
    expect(container.read(replaysTabOpenProvider), isFalse);
    expect(seen, contains(notAReplay));
    await closeToasts(tester);
  });

  testWidgets('several replays dropped on My Library land on the tab',
      (tester) async {
    final container = await pumpApp(tester);

    await dropFiles(tester, {'a.vrf': 'patch 13.06', 'b.vrf': 'patch 13.06'});

    expect(await tester.runAsync(keptReplays), ['a.vrf', 'b.vrf']);
    expect(container.read(replaysTabOpenProvider), isTrue);
    // Several replays open nothing, so nothing explains why one can't open.
    expect(seen, isNot(contains(patchReason)));
    // My Library's .ica import left them alone instead of calling them
    // unsupported files.
    expect(appProviderContainer.read(inAppDebugProvider), isEmpty);
    await closeToasts(tester);
  });

  testWidgets('staying in the editor keeps it open', (tester) async {
    final container = await pumpApp(tester, strategy: _dirtyStrategy);
    container.read(strategySaveStateProvider.notifier).markDirty();

    await dropFiles(tester, {'a.vrf': 'patch 13.06'});
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

    await dropFiles(tester, {'a.vrf': 'patch 13.06'});
    await tester.tap(find.text("Don't save"));
    await settle(tester);

    expect(find.text('Save changes?'), findsNothing);
    expect(container.read(strategyProvider).strategyName, isNull);
    expect(container.read(replaysTabOpenProvider), isTrue);
    expect(find.text('editor'), findsNothing);
    expect(seen, contains(patchReason));
    await closeToasts(tester);
  });
}
