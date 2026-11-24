import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/canvas_shows.dart';
import 'package:icarus/strategy/local_library.dart';

import 'library_rows/generated_strategies.dart';
import 'library_store/unit_harness.dart';

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

final class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

final class _Hold {
  final reached = Completer<void>();
  final released = Completer<void>();
  var fails = false;
}

final class _DiskGate {
  _DiskGate(this.directory);

  final Directory directory;
  final _armed = <_Hold>[];

  _Hold holdNext({bool fails = false}) {
    final hold = _Hold()..fails = fails;
    _armed.add(hold);
    return hold;
  }

  Future<Object?> answer(MethodCall call) async {
    if (_armed.isNotEmpty) {
      final hold = _armed.removeAt(0);
      hold.reached.complete();
      await hold.released.future;
      if (hold.fails) {
        throw PlatformException(code: 'disk', message: 'the disk is gone');
      }
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
  String? activePage() =>
      container.read(strategyPageSessionProvider).activePageId;

  StrategyData stored(
    String id, {
    int pages = 2,
    Optionals optionals = Optionals.set,
  }) {
    final strategy = generatedStrategy(optionals).copyWith(
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

  StrategyData saved(String id) => const LocalLibrary().storedStrategy(id)!;

  List<String> agentsSaved(String strategyId, String pageId) => [
        for (final agent in saved(strategyId)
            .pages
            .firstWhere((page) => page.id == pageId)
            .agentData)
          agent.id,
      ];

  List<String> agentsOnCanvas() => [
        for (final agent in container.read(agentProvider)) agent.id,
      ];

  void expectShows(String strategyId, String pageId, String step) {
    expect(
      switch (canvas()) {
        ShowsPage(strategyId: final shown, pageId: final page) =>
          shown == strategyId && page == pageId,
        ShowsNothing() => false,
      },
      isTrue,
      reason: 'after $step the canvas shows $strategyId page $pageId',
    );
  }

  void expectShowsActivePage(String step) => expectShows(
        container.read(strategyProvider).strategyId!,
        activePage()!,
        step,
      );

  test(
      'after every page path the editor has, the canvas shows the active page '
      'and the pages left are saved with what they held', () async {
    final a = stored('paths-a', pages: 3);
    final b = stored('paths-b');
    expect(canvas(), isA<ShowsNothing>(), reason: 'before any open');

    expect(await editor().loadFromHive(a.id), isTrue);
    expectShowsActivePage('an open');
    container.read(agentProvider.notifier).addAgent(PlacedAgent(
          type: AgentType.jett,
          position: const Offset(300, 300),
          id: 'added-on-p0',
        ));
    await editor().setActivePage(a.pages[1].id);
    expectShowsActivePage('a page switch');
    expect(agentsSaved(a.id, a.pages[0].id), contains('added-on-p0'));
    await editor().setActivePageAnimated(a.pages[2].id);
    expectShowsActivePage('an animated page switch');
    expect(agentsSaved(a.id, a.pages[1].id),
        [for (final agent in a.pages[1].agentData) agent.id]);
    await editor().addPage();
    expectShowsActivePage('adding a page');
    await editor().reorderPage(0, 2);
    expectShowsActivePage('moving a page');
    final active = activePage()!;
    final onScreen = agentsOnCanvas();
    expect(await editor().deletePage(active), isTrue);
    expectShowsActivePage('deleting the page on screen');
    expect(saved(a.id).pages.any((page) => page.id == active), isFalse);
    expect(agentsOnCanvas(), agentsSaved(a.id, activePage()!));
    expect(onScreen, isNotEmpty);
    await editor().saveToHive(a.id);
    expectShowsActivePage('a save');
    expect(agentsSaved(a.id, a.pages[0].id), contains('added-on-p0'));
    expect(await editor().loadFromHive(b.id), isTrue);
    expectShowsActivePage('opening another strategy');
    expect(agentsOnCanvas(), agentsSaved(b.id, b.pages[0].id));
  });

  test(
      'during an open\'s disk work the strategy left is still open, its '
      'canvas whole and saved as it is; once the other strategy is open its '
      'page is shown', () async {
    final a = stored('whole-a');
    final b = stored('whole-b');
    expect(await editor().loadFromHive(a.id), isTrue);
    final before = agentsSaved(a.id, a.pages[0].id);

    final hold = gate.holdNext();
    final opening = editor().loadFromHive(b.id);
    await hold.reached.future;
    expect(container.read(strategyProvider).strategyId, a.id);
    expect(agentsOnCanvas(), before);
    expectShows(a.id, a.pages[0].id, 'the open began');
    await editor().saveToHive(a.id);
    expect(agentsSaved(a.id, a.pages[0].id), before);
    hold.released.complete();
    expect(await opening, isTrue);

    expectShowsActivePage('the open');
    expect(agentsOnCanvas(), agentsSaved(b.id, b.pages[0].id));
  });

  test(
      'a page clicked during an open is ignored and writes nothing; the open '
      'ends on its own first page', () async {
    final a = stored('click-a');
    final b = stored('click-b');
    expect(await editor().loadFromHive(a.id), isTrue);
    final before = saved(a.id).lastEdited;

    final hold = gate.holdNext();
    final opening = editor().loadFromHive(b.id);
    await hold.reached.future;
    await editor().selectPage(a.pages[1].id);
    expect(activePage(), a.pages[0].id);
    hold.released.complete();
    expect(await opening, isTrue);

    expect(saved(a.id).lastEdited, before);
    expect(activePage(), b.pages[0].id);
    await editor().selectPage(b.pages[1].id);
    expect(activePage(), b.pages[1].id, reason: 'clicks work once it opened');
  });

  test(
      'an open that fails during its disk work leaves the strategy left open '
      'and usable', () async {
    final a = stored('failed-a');
    final b = stored('failed-b');
    expect(await editor().loadFromHive(a.id), isTrue);
    final before = agentsSaved(a.id, a.pages[0].id);

    final hold = gate.holdNext(fails: true);
    final opening = editor().loadFromHive(b.id);
    await hold.reached.future;
    hold.released.complete();
    await expectLater(opening, throwsA(isA<PlatformException>()));

    expect(container.read(strategyProvider).strategyId, a.id);
    expectShows(a.id, a.pages[0].id, 'the failed open');
    expect(agentsOnCanvas(), before);
    expect(editor().isOpening, isFalse);
    await editor().selectPage(a.pages[1].id);
    expect(activePage(), a.pages[1].id);
    expect(agentsSaved(a.id, a.pages[0].id), before);
  });

  test(
      'an open that gives way to an open of a missing strategy leaves the '
      'strategy left open and usable', () async {
    final a = stored('superseded-a');
    final b = stored('superseded-b');
    expect(await editor().loadFromHive(a.id), isTrue);
    final before = agentsSaved(a.id, a.pages[0].id);

    final hold = gate.holdNext();
    final opening = editor().loadFromHive(b.id);
    await hold.reached.future;
    expect(await editor().loadFromHive('not-in-the-library'), isFalse);
    hold.released.complete();
    expect(await opening, isFalse);

    expect(container.read(strategyProvider).strategyId, a.id);
    expectShows(a.id, a.pages[0].id, 'the superseded open');
    expect(agentsOnCanvas(), before);
    expect(editor().isOpening, isFalse);
    await editor().selectPage(a.pages[1].id);
    expect(activePage(), a.pages[1].id);
  });

  test(
      'with two opens overlapping, a click stays ignored until the later one '
      'has ended, though the earlier one ended first', () async {
    final a = stored('overlap-a');
    final b = stored('overlap-b');
    final c = stored('overlap-c');
    expect(await editor().loadFromHive(a.id), isTrue);

    final holdB = gate.holdNext();
    final holdC = gate.holdNext();
    final openingB = editor().loadFromHive(b.id);
    await holdB.reached.future;
    final openingC = editor().loadFromHive(c.id);
    holdB.released.complete();
    expect(await openingB, isFalse);
    await holdC.reached.future;

    expect(editor().isOpening, isTrue);
    expect(editor().ignoresClick(a.pages[1].id), isTrue);
    holdC.released.complete();
    expect(await openingC, isTrue);

    expect(editor().isOpening, isFalse);
    await editor().selectPage(c.pages[1].id);
    expect(activePage(), c.pages[1].id);
  });

  test('closing during an open ends the open and leaves nothing open',
      () async {
    final a = stored('close-a');
    final b = stored('close-b');
    expect(await editor().loadFromHive(a.id), isTrue);
    final before = agentsSaved(a.id, a.pages[0].id);

    final hold = gate.holdNext();
    final opening = editor().loadFromHive(b.id);
    await hold.reached.future;
    await editor().clearCurrentStrategy();
    hold.released.complete();

    expect(await opening, isFalse);
    expect(container.read(strategyProvider).strategyId, isNull);
    expect(editor().isOpening, isFalse);
    expect(agentsSaved(a.id, a.pages[0].id), before);
  });

  test(
      'a strategy whose record is gone by the time it becomes open is left '
      'open over an empty canvas that nothing can be saved from', () async {
    final a = stored('gone-a');
    final b = stored('gone-b');
    expect(await editor().loadFromHive(a.id), isTrue);
    final before = saved(a.id).lastEdited;

    final hold = gate.holdNext();
    final opening = editor().loadFromHive(b.id);
    await hold.reached.future;
    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).delete(b.id);
    hold.released.complete();
    await opening;

    expect(container.read(strategyProvider).strategyId, b.id);
    expect(canvas(), isA<ShowsNothing>());
    expect(agentsOnCanvas(), isEmpty);
    await editor().saveToHive(b.id);
    expect(const LocalLibrary().storedStrategy(b.id), isNull);
    expect(saved(a.id).lastEdited, before);
  });

  test(
      'two page clicks at once end on the second, and the page left keeps '
      'what it held', () async {
    final a = stored('fast-a', pages: 3);
    expect(await editor().loadFromHive(a.id), isTrue);
    final p0 = agentsSaved(a.id, a.pages[0].id);
    final p1 = agentsSaved(a.id, a.pages[1].id);

    final first = editor().selectPage(a.pages[1].id);
    final second = editor().selectPage(a.pages[2].id);
    await first;
    await second;

    expect(activePage(), a.pages[2].id);
    expectShowsActivePage('two quick clicks');
    expect(agentsSaved(a.id, a.pages[0].id), p0);
    expect(agentsSaved(a.id, a.pages[1].id), p1);
  });

  test(
      'a Save asked for a strategy that is no longer open writes nothing to '
      'it, and fails loudly when there is unsaved work', () async {
    final a = stored('stale-a', optionals: Optionals.unset);
    final b = stored('stale-b');
    expect(a.mapData, isNot(b.mapData));
    expect(await editor().loadFromHive(a.id), isTrue);
    expect(await editor().loadFromHive(b.id), isTrue);
    final before = saved(a.id);

    await editor().saveToHive(a.id);
    container.read(mapProvider.notifier).fromHive(MapValue.haven, true);
    editor().setUnsaved();
    await expectLater(editor().saveToHive(a.id), throwsStateError);

    final after = saved(a.id);
    expect(after.mapData, before.mapData);
    expect(after.themeProfileId, before.themeProfileId);
    expect(after.lastEdited, before.lastEdited);
    expect(
      [for (final page in after.pages) page.agentData.length],
      [for (final page in before.pages) page.agentData.length],
    );
  });
}
