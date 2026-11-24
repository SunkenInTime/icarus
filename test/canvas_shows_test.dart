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
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
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
  var passFirst = 0;
}

final class _DiskGate {
  _DiskGate(this.directory);

  final Directory directory;
  final _armed = <_Hold>[];

  _Hold holdNext({bool fails = false, int passFirst = 0}) {
    final hold = _Hold()
      ..fails = fails
      ..passFirst = passFirst;
    _armed.add(hold);
    return hold;
  }

  Future<Object?> answer(MethodCall call) async {
    if (_armed.firstOrNull case final next? when next.passFirst > 0) {
      next.passFirst--;
    } else if (_armed.isNotEmpty) {
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
    final onScreenBeforeMove = activePage();
    final orderBeforeMove = [
      for (final page
          in saved(a.id).pages.toList()
            ..sort((x, y) => x.sortIndex.compareTo(y.sortIndex)))
        page.id,
    ];
    await editor().reorderPage(0, 2);
    expect(
      [
        for (final page
            in saved(a.id).pages.toList()
              ..sort((x, y) => x.sortIndex.compareTo(y.sortIndex)))
          page.id,
      ],
      isNot(orderBeforeMove),
    );
    expect(activePage(), onScreenBeforeMove);
    expectShowsActivePage('moving a page');
    expect(agentsOnCanvas(), agentsSaved(a.id, activePage()!));
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
    final before = saved(a.id).lastEdited;
    await editor().selectPage(a.pages[1].id);
    expect(activePage(), a.pages[0].id);
    expect(saved(a.id).lastEdited, before);
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
      'a Save that a map change and a page click overtake does not put the '
      'old map back', () async {
    final a = stored('overtaken-save');
    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .put(a.id, a.copyWith(mapData: MapValue.haven));
    expect(await editor().loadFromHive(a.id), isTrue);
    expect(container.read(mapProvider).currentMap, MapValue.haven);

    final saving = editor().saveToHive(a.id);
    container.read(mapProvider.notifier).updateMap(MapValue.lotus);
    editor().setUnsaved();
    final switching = editor().selectPage(a.pages[1].id);
    await saving;
    await switching;

    expect(container.read(mapProvider).currentMap, MapValue.lotus);
    expect(saved(a.id).mapData, MapValue.lotus);
  });

  test(
      'settings applied to all pages while another strategy opens write '
      'nothing to the strategy opened', () async {
    final a = stored('all-pages-a');
    final b = stored('all-pages-b');
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    await box.put(a.id, a.copyWith(mapData: MapValue.haven));
    await box.put(b.id, b.copyWith(mapData: MapValue.lotus));
    expect(await editor().loadFromHive(a.id), isTrue);
    final before = saved(b.id);

    final hold = gate.holdNext(passFirst: 1);
    final opening = editor().loadFromHive(b.id);
    await hold.reached.future;
    final ahead = box.put('written-ahead', stored('written-ahead', pages: 400));
    final applying = editor().applyNeutralTeamColorsToAllPages(
      !before.pages.first.settings.useNeutralTeamColors,
    );
    hold.released.complete();
    await ahead;
    expect(await opening, isTrue);
    await applying;

    final after = saved(b.id);
    expect(container.read(strategyProvider).strategyId, b.id);
    expect(after.mapData, MapValue.lotus);
    expect(after.themeProfileId, before.themeProfileId);
    expect(
      [for (final page in after.pages) page.settings.useNeutralTeamColors],
      [for (final page in before.pages) page.settings.useNeutralTeamColors],
    );
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

  test(
      'a Save of one strategy that resumes after another has opened writes '
      'nothing of the other into it', () async {
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final a = stored('resumed-a');
    final b = stored('resumed-b', optionals: Optionals.unset);
    await box.put(a.id, a.copyWith(mapData: MapValue.haven));
    await box.put(b.id, b.copyWith(mapData: MapValue.lotus));
    expect(saved(a.id).themeProfileId, isNotNull);
    expect(saved(b.id).themeProfileId, isNull);
    expect(await editor().loadFromHive(a.id), isTrue);
    container.read(agentProvider.notifier).addAgent(PlacedAgent(
          type: AgentType.jett,
          position: const Offset(300, 300),
          id: 'saved-on-a',
        ));
    editor().setUnsaved();
    final onA = agentsOnCanvas();

    final ahead = box.put('written-ahead', stored('written-ahead', pages: 400));
    final saving = editor().saveToHive(a.id);
    expect(await editor().loadFromHive(b.id), isTrue);
    await ahead;
    await saving;

    expect(saved(a.id).mapData, MapValue.haven);
    expect(saved(a.id).themeProfileId, isNotNull);
    expect(await editor().loadFromHive(a.id), isTrue);
    expect(agentsOnCanvas(), onA);
    expect(container.read(mapProvider).currentMap, MapValue.haven);
  });

  group('with the canvas not showing the page on screen', () {
    String fingerprint(String id) {
      final strategy = saved(id);
      return [
        strategy.mapData,
        strategy.themeProfileId,
        strategy.lastEdited,
        for (final page in strategy.pages)
          [
            page.id,
            page.isAttack,
            page.settings.toJson(),
            [for (final agent in page.agentData) agent.id],
            [for (final link in page.lineUpGraph.links) link.id],
          ],
      ].toString();
    }

    final writers = <String, Future<Object?> Function(StrategyProvider)>{
      'a page click': (editor) => editor.selectPage('writer-p1'),
      'a Save': (editor) => editor.saveToHive('writer'),
      'copying an item to the next page': (editor) =>
          editor.copyPlacedWidgetToAdjacentPage(
            widgetId: 'edited-here',
            direction: PageTransitionDirection.forward,
          ),
      'copying lineups to the next page': (editor) =>
          editor.copyLineUpsToAdjacentPage(
            linkIds: {
              for (final link in container.read(lineUpProvider).links) link.id,
            },
            direction: PageTransitionDirection.forward,
          ),
      'marker sizes on all pages': (editor) =>
          editor.applyMarkerSizesToAllPages(),
      'neutral colours on all pages': (editor) =>
          editor.applyNeutralTeamColorsToAllPages(true),
      'switching side on all pages': (editor) =>
          editor.switchSide(allPages: true),
      'adding a page': (editor) => editor.addPage(),
    };

    for (final MapEntry(key: step, value: write) in writers.entries) {
      test('$step writes nothing', () async {
        await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).put(
          'writer',
          generatedStrategy(Optionals.set).copyWith(id: 'writer', pages: [
            for (final index in [0, 1, 2])
              generatedPage(
                id: 'writer-p$index',
                sortIndex: index,
                optionals: Optionals.set,
                isAttack: true,
                itemPrefix: 'writer-p$index',
                lineups: sharedSpotLineups('writer-p$index'),
              ),
          ]),
        );
        expect(await editor().loadFromHive('writer'), isTrue);
        expect(container.read(lineUpProvider).links, isNotEmpty);
        container.read(agentProvider.notifier).addAgent(PlacedAgent(
              type: AgentType.jett,
              position: const Offset(300, 300),
              id: 'edited-here',
            ));
        editor().setUnsaved();
        final before = fingerprint('writer');

        container.read(canvasShowsProvider.notifier).emptied();
        await write(editor()).then<Object?>(
          (result) => result,
          onError: (Object error) => error is StateError ? error : throw error,
        );

        expect(fingerprint('writer'), before);
        expect(activePage(), 'writer-p0');
      });
    }
  });
}
