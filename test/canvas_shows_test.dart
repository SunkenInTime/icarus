import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/strategy/canvas_shows.dart';
import 'package:icarus/strategy/local_library.dart';

import 'library_rows/generated_strategies.dart';
import 'library_store/unit_harness.dart';

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

final class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

final class _DiskGate {
  _DiskGate(this.directory);

  final Directory directory;
  Completer<void>? _held;
  Completer<void>? _reached;

  Future<void> holdNext() {
    _held = Completer<void>();
    return (_reached = Completer<void>()).future;
  }

  void release() => _held?.complete();

  Future<Object?> answer(MethodCall call) async {
    if (_reached case final reached? when !reached.isCompleted) {
      reached.complete();
      await _held!.future;
    }
    return directory.path;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late _DiskGate gate;
  setUpAll(() {
    container = ProviderContainer(
      overrides: [authProvider.overrideWith(_SignedOut.new)],
    );
    appProviderContainer = container;
  });
  setUp(() async {
    gate = _DiskGate(await openUnitHive());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, gate.answer);
  });
  tearDown(() async {
    await container.read(strategyProvider.notifier).clearCurrentStrategy();
    await Hive.close();
  });

  StrategyProvider editor() => container.read(strategyProvider.notifier);
  CanvasShows canvas() => container.read(canvasShowsProvider);

  StrategyData stored(String id, {int pages = 2}) {
    final strategy = generatedStrategy(Optionals.set).copyWith(
      id: id,
      pages: [
        for (var index = 0; index < pages; index++)
          generatedPage(
            id: '$id-p$index',
            sortIndex: index,
            optionals: Optionals.set,
            isAttack: true,
            itemPrefix: '$id-p$index',
          ),
      ],
    );
    unawaited(
      Hive.box<StrategyData>(HiveBoxNames.strategiesBox).put(id, strategy),
    );
    return strategy;
  }

  List<String> agentsSaved(String strategyId, String pageId) => [
        for (final agent in const LocalLibrary()
            .storedStrategy(strategyId)!
            .pages
            .firstWhere((page) => page.id == pageId)
            .agentData)
          agent.id,
      ];

  void expectShowsActivePage(String step) {
    final strategyId = container.read(strategyProvider).strategyId;
    final pageId = container.read(strategyPageSessionProvider).activePageId;
    expect(
      switch (canvas()) {
        ShowsPage(strategyId: final shown, pageId: final page) =>
          shown == strategyId && page == pageId,
        _ => false,
      },
      isTrue,
      reason: 'after $step the canvas shows $strategyId page $pageId',
    );
  }

  test(
      'after every page path the editor has today, the canvas shows the '
      'active page of the open strategy, so every flush writes as before',
      () async {
    final a = stored('paths-a', pages: 3);
    final b = stored('paths-b');
    expect(canvas(), isA<ShowsNothing>(), reason: 'before any open');

    expect(await editor().loadFromHive(a.id), isTrue);
    expectShowsActivePage('an open');
    await editor().setActivePage(a.pages[1].id);
    expectShowsActivePage('a page switch');
    await editor().setActivePageAnimated(a.pages[2].id);
    expectShowsActivePage('an animated page switch');
    await editor().addPage();
    expectShowsActivePage('adding a page');
    await editor().reorderPage(0, 2);
    expectShowsActivePage('moving a page');
    final active = container.read(strategyPageSessionProvider).activePageId!;
    expect(await editor().deletePage(active), isTrue);
    expectShowsActivePage('deleting the page on screen');
    await editor().saveToHive(a.id);
    expectShowsActivePage('a save');
    expect(await editor().loadFromHive(b.id), isTrue);
    expectShowsActivePage('opening another strategy');
    await editor().clearCurrentStrategy();
    expect(canvas(), isA<ShowsPage>(),
        reason: 'closing leaves the canvas as it is');
  });

  test(
      'a page of the open strategy clicked while it is being opened again is '
      'shown once the open has applied, and the page on screen keeps what it '
      'had', () async {
    final a = stored('again-a');
    expect(await editor().loadFromHive(a.id), isTrue);
    final before = agentsSaved(a.id, a.pages[0].id);

    final held = gate.holdNext();
    final opening = editor().loadFromHive(a.id);
    await held;
    final switching = editor().setActivePageAnimated(a.pages[1].id);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(canvas(), isA<WaitsToShow>());
    gate.release();
    await opening;
    await switching;

    expect(agentsSaved(a.id, a.pages[0].id), before);
    expect(container.read(strategyPageSessionProvider).activePageId,
        a.pages[1].id);
    expectShowsActivePage('the open and the page it waited to show');
  });

  test(
      'a page wanted during an open is dropped when the strategy is closed '
      'or another open begins', () {
    final shows = container.read(canvasShowsProvider.notifier);
    shows.emptied();
    shows.want('a', 'a-p1');
    shows.dropWanted();
    expect(shows.shown('a', 'a-p0'), isNull);

    shows.emptied();
    shows.want('a', 'a-p1');
    shows.emptied();
    expect(shows.shown('a', 'a-p0'), isNull);

    shows.emptied();
    shows.want('a', 'a-p1');
    expect(shows.shown('b', 'b-p0'), isNull,
        reason: 'a page of the strategy left is not shown in the one opened');

    shows.emptied();
    shows.want('a', 'a-p1');
    expect(shows.shown('a', 'a-p0'), 'a-p1');
    expect(shows.shown('a', 'a-p1'), isNull, reason: 'it runs once');
  });

  test(
      'a save while an open has emptied the canvas writes nothing; with '
      'nothing unsaved it ends quietly, and the strategy left is as it was',
      () async {
    final a = stored('save-a');
    final b = stored('save-b');
    expect(await editor().loadFromHive(a.id), isTrue);
    final record = const LocalLibrary().storedStrategy(a.id)!;
    final edited = record.lastEdited;

    final held = gate.holdNext();
    final opening = editor().loadFromHive(b.id);
    await held;
    await editor().saveToHive(a.id);
    gate.release();
    await opening;

    expect(const LocalLibrary().storedStrategy(a.id)!.lastEdited, edited);
    expect(agentsSaved(a.id, a.pages[0].id), isNotEmpty);
  });

  test(
      'work put on the emptied canvas during an open is not reported saved: '
      'a save fails loudly, the strategy stays unsaved, and closing is not '
      'safe until the open has replaced the canvas', () async {
    final a = stored('unsaved-a');
    final b = stored('unsaved-b');
    expect(await editor().loadFromHive(a.id), isTrue);

    final held = gate.holdNext();
    final opening = editor().loadFromHive(b.id);
    await held;
    container.read(agentProvider.notifier).addAgent(
          PlacedAgent(
            type: AgentType.jett,
            position: const Offset(400, 400),
            id: 'put-in-the-window',
          ),
        );
    editor().setUnsaved();
    expect(container.read(strategySaveStateProvider).isDirty, isTrue);
    await expectLater(editor().saveToHive(a.id), throwsStateError);
    expect(container.read(strategySaveStateProvider).isDirty, isTrue);
    await expectLater(
      editor().flushPendingAutosaveBeforeExit(),
      throwsStateError,
      reason: 'the unsaved-work guard catches this, says the save failed and '
          'does not close',
    );
    expect(container.read(strategySaveStateProvider).isDirty, isTrue);
    gate.release();
    await opening;

    expect(agentsSaved(a.id, a.pages[0].id), isNotEmpty);
    expect(
        agentsSaved(a.id, a.pages[0].id), isNot(contains('put-in-the-window')));
    expect(
      [for (final agent in container.read(agentProvider)) agent.id],
      isNot(contains('put-in-the-window')),
      reason: 'the open replaces the canvas, as it does on main',
    );
  });
}
