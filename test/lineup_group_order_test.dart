import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/page_copy_id.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';

import 'library_rows/generated_strategies.dart';

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
  _Editor() {
    container = ProviderContainer(
      overrides: [actionProvider.overrideWith(_TestActionProvider.new)],
    );
    addTearDown(container.dispose);
  }

  late final ProviderContainer container;
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

  test('undoing the deletion of the first of two lineups puts it back first',
      () {
    final editor = _Editor();
    final a1 = editor.fresh();
    final a2 = editor.fromOrigin(a1.originId);
    final placed = _orderOf(editor.state.graph);

    editor.lineUps.deleteLink(a1.id);
    editor.history.undoAction();

    expect(_orderOf(editor.state.graph), placed);
    expect(placed['links'], [a1.id, a2.id]);
    editor.history.redoAction();
    editor.history.undoAction();
    expect(_orderOf(editor.state.graph), placed);
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

  test('generated edits keep the editor in the order the page reads back in',
      () {
    for (var seed = 0; seed < 150; seed++) {
      final random = Random(seed);
      final editor = _Editor();
      final steps = <String>[];
      T pick<T>(List<T> from) => from[random.nextInt(from.length)];

      for (var step = 0; step < 40; step++) {
        final state = editor.state;
        final roll = state.links.isEmpty ? 0 : random.nextInt(10);
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
          case 7:
            editor.history.redoAction();
            steps.add('redo');
          case 8:
            final picked = {
              for (final link in state.links)
                if (random.nextBool()) link.id,
            };
            editor.lineUps.addCopies(state.graph.copyOfLinks(picked));
            steps.add('paste ${picked.length}');
          case _:
            final page = generatedPage(
              id: 'source',
              sortIndex: 0,
              optionals: Optionals.unset,
              isAttack: true,
            ).copyWith(lineUpGraph: state.graph);
            editor.lineUps.fromHive(page.copyWith(id: 'copy').lineUpGraph);
            steps.add('copy page');
        }
        editor.expectReadOrder('seed $seed: ${steps.join(', ')}');
      }
    }
  });
}
