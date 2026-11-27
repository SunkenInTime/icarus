import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/page_copy_id.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';

import 'library_rows/generated_strategies.dart';

class _QueueThatChanges extends StrategyOpQueueNotifier {
  @override
  StrategyOpQueueState build() => const StrategyOpQueueState();

  void change() => state = state.copyWith(lastError: 'changed');
}

class _TestActionProvider extends ActionProvider {
  @override
  List<UserAction> build() => [];

  @override
  void addAction(UserAction action) {
    poppedItems = [];
    state = [...state, action];
  }
}

Map<String, List<String>> _orderOf(LineUpGraph graph) => {
      'origins': [for (final origin in graph.origins) origin.id],
      'landings': [for (final landing in graph.landings) landing.id],
      'links': [for (final link in graph.links) link.id],
    };

LineUpGraph _readBack(LineUpGraph graph) {
  final page = generatedPage(
    id: 'page',
    sortIndex: 0,
    optionals: Optionals.unset,
    isAttack: true,
  ).copyWith(lineUpGraph: graph);
  final strategy = StrategyData(
    id: 'strategy',
    name: 'Order',
    mapData: MapValue.ascent,
    versionNumber: Settings.versionNumber,
    lastEdited: DateTime.utc(2026, 11, 21),
    createdAt: DateTime.utc(2026, 11, 21),
    folderID: null,
    pages: [page],
  );
  final made = strategyToRows(strategy) as StrategyRowsMade;
  final back = strategyFromRows(made.rows) as StrategyDataMade;
  return back.strategy.pages.single.lineUpGraph;
}

class _Editor {
  _Editor([ProviderContainer? inStrategy])
      : container = inStrategy ??
            ProviderContainer(
              overrides: [actionProvider.overrideWith(_TestActionProvider.new)],
            ) {
    addTearDown(container.dispose);
  }

  final ProviderContainer container;
  var _next = 0;

  LineUpProvider get lineUps => container.read(lineUpProvider.notifier);
  ActionProvider get history => container.read(actionProvider.notifier);
  LineUpState get state => container.read(lineUpProvider);

  PlacedAgent _agent() => PlacedAgent(
        id: 'agent-${_next++}',
        type: AgentType.sova,
        position: Offset(100.0 + _next, 100),
        isAlly: true,
      );

  PlacedAbility _ability() => PlacedAbility(
        id: 'ability-${_next++}',
        data: AgentData.agents[AgentType.sova]!.abilities.first,
        position: const Offset(400, 400),
        isAlly: true,
      );

  LineUpLink fresh() {
    lineUps
      ..startFresh()
      ..setDraftAgent(_agent())
      ..setDraftAbility(_ability());
    return lineUps.commitPlacement()!;
  }

  LineUpLink fromOrigin(String originId) {
    lineUps
      ..startFromOrigin(originId)
      ..setDraftAbility(_ability());
    return lineUps.commitPlacement()!;
  }

  LineUpLink toLanding(String landingId) {
    lineUps
      ..startToLanding(landingId)
      ..setDraftAgent(_agent());
    return lineUps.commitPlacement()!;
  }

  void expectReadOrder(String reason) {
    final graph = state.graph;
    expect(_orderOf(graph), _orderOf(_readBack(graph)), reason: reason);
  }
}

void _expectBroughtBackLast(
  LineUpGraph before,
  LineUpGraph after,
  String reason,
) {
  final had = {for (final link in before.links) link.id};
  final groupOf = <String, String>{
    for (final (:id, :lineUps) in lineupGroups(after))
      for (final link in lineUps.links) link.id: id,
  };
  final order = [for (final link in after.links) link.id];
  for (final (index, id) in order.indexed) {
    if (had.contains(id)) continue;
    final laterOldOnes = [
      for (final later in order.skip(index + 1))
        if (had.contains(later) && groupOf[later] == groupOf[id]) later,
    ];
    expect(laterOldOnes, isEmpty, reason: '$reason: $id came back before them');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => appProviderContainer = ProviderContainer());
  tearDownAll(() => appProviderContainer.dispose());
  setUp(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  test(
      'a lineup from a standing spot already on the page goes after its lineups',
      () {
    final editor = _Editor();
    final a1 = editor.fresh();
    final b1 = editor.fresh();
    final a2 = editor.fromOrigin(a1.originId);

    expect(_orderOf(editor.state.graph), {
      'origins': [a1.originId, b1.originId],
      'landings': [a1.landingId, a2.landingId, b1.landingId],
      'links': [a1.id, a2.id, b1.id],
    });
    editor.expectReadOrder('A1, B1, then A2 from A');
  });

  test('a lineup into a landing already on the page goes after its lineups',
      () {
    final editor = _Editor();
    final a1 = editor.fresh();
    final b1 = editor.fresh();
    final a2 = editor.toLanding(a1.landingId);

    expect(_orderOf(editor.state.graph)['links']!, [a1.id, a2.id, b1.id]);
    editor.expectReadOrder('A1, B1, then A2 into A');
  });

  test('undoing the deletion of the first of two lineups brings it back last',
      () {
    final editor = _Editor();
    final a1 = editor.fresh();
    final a2 = editor.fromOrigin(a1.originId);
    final b1 = editor.fresh();

    editor.lineUps.deleteLink(a1.id);
    editor.history.undoAction();

    expect(_orderOf(editor.state.graph)['links'], [a2.id, a1.id, b1.id]);
    editor.expectReadOrder('after undo');
    editor.history.redoAction();
    editor.history.undoAction();
    expect(_orderOf(editor.state.graph)['links'], [a2.id, a1.id, b1.id]);
    editor.expectReadOrder('after redo and undo');
  });

  test('undoing an addition and redoing it puts the lineup back in its place',
      () {
    final editor = _Editor();
    final a1 = editor.fresh();
    final a2 = editor.fromOrigin(a1.originId);
    final b1 = editor.fresh();
    final a3 = editor.fromOrigin(a1.originId);

    editor.history.undoAction();
    editor.history.redoAction();

    expect(
        _orderOf(editor.state.graph)['links']!, [a1.id, a2.id, a3.id, b1.id]);
    editor.expectReadOrder('after redo');
  });

  (LineUpLink, LineUpLink, LineUpLink, LineUpLink) joinedThroughOne(
    _Editor editor,
  ) {
    final a = editor.fresh();
    final b = editor.fromOrigin(a.originId);
    final c = editor.toLanding(b.landingId);
    final d = editor.fromOrigin(a.originId);
    expect(_orderOf(editor.state.graph)['links']!, [a.id, b.id, c.id, d.id]);
    return (a, b, c, d);
  }

  test('deleting the lineup that joined two groups keeps each group together',
      () {
    final editor = _Editor();
    final (a, b, c, d) = joinedThroughOne(editor);

    editor.lineUps.deleteLink(b.id);

    expect(_orderOf(editor.state.graph)['links']!, [a.id, d.id, c.id]);
    editor.expectReadOrder('after deleting the joining lineup');
  });

  test(
      'undoing the deletion of a joining lineup brings it back last in the '
      'group it joins again', () {
    final editor = _Editor();
    final (a, b, c, d) = joinedThroughOne(editor);

    editor.lineUps.deleteLink(b.id);
    editor.history.undoAction();

    expect(_orderOf(editor.state.graph)['links']!, [a.id, d.id, c.id, b.id]);
    editor.expectReadOrder('after undo');
  });

  test('pasted lineups whose group is split by the copy paste group by group',
      () {
    final editor = _Editor();
    final (a, _, c, d) = joinedThroughOne(editor);

    final copies = editor.state.graph.copyOfLinks({a.id, c.id, d.id});
    editor.lineUps.addCopies(copies);

    final pasted = _orderOf(editor.state.graph)['links']!.skip(4);
    expect(pasted.map(pageCopyRoot), [a.id, d.id, c.id]);
    editor.expectReadOrder('after pasting');
  });

  test('lineups saved interleaved load in their saved order', () {
    final editor = _Editor();
    final graph = sharedSpotLineups('page');
    final interleaved = LineUpGraph(
      origins: graph.origins,
      landings: graph.landings,
      links: [graph.links[3], ...graph.links.take(3)],
    );

    editor.lineUps.fromHive(interleaved);

    expect(_orderOf(editor.state.graph), _orderOf(interleaved));
  });

  group('in a strategy on this device', () {
    late Directory store;
    late Box<StrategyData> strategies;

    setUp(() async {
      store = await Directory.systemTemp.createTemp('icarus-lineup-order-');
      Hive.init(store.path);
      if (!Hive.isAdapterRegistered(9)) registerIcarusAdapters(Hive);
      strategies = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
      await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
      await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
      await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
      await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
    });

    tearDown(() async {
      await Hive.close();
      await store.delete(recursive: true);
    });

    Future<_Editor> open(List<StrategyPage> pages) async {
      final strategy = StrategyData(
        id: 'strategy',
        name: 'Order',
        mapData: MapValue.ascent,
        versionNumber: Settings.versionNumber,
        lastEdited: DateTime.utc(2026, 11, 21),
        folderID: null,
        pages: pages,
      );
      await strategies.put(strategy.id, strategy);
      final container = ProviderContainer(
        overrides: [
          strategyOpQueueProvider.overrideWith(_QueueThatChanges.new)
        ],
      );
      container.read(strategyPageSessionProvider);
      container.read(strategyProvider.notifier)
        ..setFromState(
          StrategyState(
            isSaved: true,
            stratName: strategy.name,
            id: strategy.id,
            storageDirectory: null,
            activePageId: pages.first.id,
          ),
        )
        ..activePageID = pages.first.id;
      container.read(lineUpProvider.notifier).fromHive(pages.first.lineUpGraph);
      return _Editor(container);
    }

    StrategyPage page(String id, int sortIndex, [LineUpGraph? lineUps]) =>
        generatedPage(
          id: id,
          sortIndex: sortIndex,
          optionals: Optionals.unset,
          isAttack: true,
        ).copyWith(lineUpGraph: lineUps ?? LineUpGraph.empty);

    LineUpGraph saved(String pageId) => strategies
        .get('strategy')!
        .pages
        .singleWhere((page) => page.id == pageId)
        .lineUpGraph;

    test(
        'a local strategy keeps a restored lineup last in its group whatever '
        'the cloud queue does', () async {
      final editor = await open([page('one', 0)]);
      final a1 = editor.fresh();
      final a2 = editor.fromOrigin(a1.originId);
      editor.lineUps.deleteLink(a1.id);
      editor.history.undoAction();
      final restored = _orderOf(editor.state.graph);
      expect(restored['links'], [a2.id, a1.id]);

      (editor.container.read(strategyOpQueueProvider.notifier)
              as _QueueThatChanges)
          .change();
      await pumpEventQueue();

      expect(_orderOf(editor.state.graph), restored);
      await editor.container.read(strategyProvider.notifier).addPage();
      expect(_orderOf(saved('one')), restored);
    });

    test('a copy of a page saved interleaved is written in group order',
        () async {
      final graph = sharedSpotLineups('one');
      final interleaved = LineUpGraph(
        origins: graph.origins,
        landings: graph.landings,
        links: [graph.links[3], ...graph.links.take(3)],
      );
      expect(_orderOf(interleaved), isNot(_orderOf(_readBack(interleaved))));
      final editor = await open([page('one', 0, interleaved)]);

      await editor.container.read(strategyProvider.notifier).addPage();

      final copyId = editor.container.read(strategyProvider).activePageId!;
      expect(copyId, isNot('one'));
      final copy = saved(copyId);
      expect(_orderOf(copy), _orderOf(_readBack(copy)));
      expect(_orderOf(editor.state.graph), _orderOf(copy));
      expect(_orderOf(saved('one')), _orderOf(interleaved));
    });

    test('lineups copied onto a page saved interleaved leave it grouped',
        () async {
      final graph = sharedSpotLineups('next');
      final interleaved = LineUpGraph(
        origins: graph.origins,
        landings: graph.landings,
        links: [graph.links[3], ...graph.links.take(3)],
      );
      final editor = await open([page('one', 0), page('next', 1, interleaved)]);
      final a = editor.fresh();

      final result = await editor.container
          .read(strategyProvider.notifier)
          .copyLineUpsToAdjacentPage(
        linkIds: {a.id},
        direction: PageTransitionDirection.forward,
      );

      expect(result, PageCopyResult.copied);
      final next = saved('next');
      expect(next.links, hasLength(5));
      expect(_orderOf(next), _orderOf(_readBack(next)));
    });

    test('generated edits keep the editor in the order the page reads back in',
        () async {
      for (var seed = 0; seed < 40; seed++) {
        final random = Random(seed);
        final editor = await open([page('page-$seed', 0)]);
        final strategy = editor.container.read(strategyProvider.notifier);
        final steps = <String>[];
        T pick<T>(List<T> from) => from[random.nextInt(from.length)];

        for (var step = 0; step < 30; step++) {
          final state = editor.state;
          final roll = state.links.isEmpty ? 0 : random.nextInt(11);
          switch (roll) {
            case 0 || 1:
              editor.fresh();
              steps.add('fresh');
            case 2 || 3:
              editor.fromOrigin(pick(state.origins).id);
              steps.add('from origin');
            case 4:
              editor.toLanding(pick(state.landings).id);
              steps.add('to landing');
            case 5:
              switch (random.nextInt(3)) {
                case 0:
                  editor.lineUps.deleteLink(pick(state.links).id);
                  steps.add('delete lineup');
                case 1:
                  editor.lineUps.deleteOrigin(pick(state.origins).id);
                  steps.add('delete origin');
                case _:
                  editor.lineUps.deleteLanding(pick(state.landings).id);
                  steps.add('delete landing');
              }
            case 6:
              editor.history.undoAction();
              steps.add('undo');
              _expectBroughtBackLast(
                state.graph,
                editor.state.graph,
                'seed $seed: ${steps.join(', ')}',
              );
            case 7:
              editor.history.redoAction();
              steps.add('redo');
              _expectBroughtBackLast(
                state.graph,
                editor.state.graph,
                'seed $seed: ${steps.join(', ')}',
              );
            case 8:
              final picked = {
                for (final link in state.links)
                  if (random.nextBool()) link.id,
              };
              editor.lineUps.addCopies(state.graph.copyOfLinks(picked));
              steps.add('paste ${picked.length}');
            case 9:
              final link = pick(state.links);
              final result = await strategy.copyLineUpsToAdjacentPage(
                linkIds: {
                  for (final other in state.links)
                    if (other.originId == link.originId) other.id,
                },
                direction: PageTransitionDirection.backward,
              );
              steps.add('copy to the page before: ${result.name}');
              final before = editor.container.read(strategyProvider);
              final pages = [...strategies.get('strategy')!.pages]
                ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
              final index =
                  pages.indexWhere((page) => page.id == before.activePageId);
              if (index > 0) {
                final there = pages[index - 1].lineUpGraph;
                expect(
                  _orderOf(there),
                  _orderOf(_readBack(there)),
                  reason: 'seed $seed: ${steps.join(', ')}',
                );
              }
            case _:
              await strategy.addPage();
              steps.add('copy page');
              final copied = saved(
                editor.container.read(strategyProvider).activePageId!,
              );
              expect(
                _orderOf(editor.state.graph),
                _orderOf(copied),
                reason: 'seed $seed: ${steps.join(', ')}',
              );
          }
          editor.expectReadOrder('seed $seed: ${steps.join(', ')}');
        }
        editor.container.dispose();
        await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).clear();
      }
    });
  });
}
