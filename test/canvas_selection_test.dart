import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/canvas_selection_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

class _NoopStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() {
    return const StrategyState(
      strategyId: 'test-strategy',
      strategyName: null,
      source: StrategySource.local,
      storageDirectory: null,
      isOpen: true,
    );
  }

  @override
  void setUnsaved() {}
}

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [strategyProvider.overrideWith(_NoopStrategyProvider.new)],
  );
  addTearDown(container.dispose);
  // Built before the page changes under it, as the canvas builds it.
  container.listen(canvasSelectionProvider, (_, __) {});
  return container;
}

PlacedAgent _agent(String id, Offset position) =>
    PlacedAgent(id: id, type: AgentType.jett, position: position);

Line _line(String id) => Line(
      lineStart: const Offset(100, 100),
      lineEnd: const Offset(200, 200),
      color: Colors.white,
      boundingBox: null,
      isDotted: false,
      hasArrow: false,
      id: id,
    );

const _a = (kind: SelectableKind.agent, id: 'a');
const _b = (kind: SelectableKind.agent, id: 'b');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => CoordinateSystem(playAreaSize: const Size(1920, 1080)));

  test('deleting a selection undoes in one step', () {
    final container = _container();
    container.read(agentProvider.notifier).fromHive([
      _agent('a', const Offset(10, 10)),
      _agent('b', const Offset(20, 20)),
      _agent('c', const Offset(30, 30)),
    ]);
    container.read(textProvider.notifier).fromHive([
      PlacedText(id: 't', position: const Offset(40, 40)),
    ]);
    container.read(drawingProvider.notifier).fromHive([_line('d')]);
    final selection = container.read(canvasSelectionProvider.notifier);

    selection.select([
      _a,
      _b,
      (kind: SelectableKind.text, id: 't'),
      (kind: SelectableKind.drawing, id: 'd'),
    ]);
    selection.deleteSelected();

    expect(container.read(agentProvider).map((agent) => agent.id), ['c']);
    expect(container.read(textProvider), isEmpty);
    expect(container.read(drawingProvider).elements, isEmpty);
    expect(container.read(canvasSelectionProvider), isEmpty);

    container.read(actionProvider.notifier).undoAction();

    expect(
      container.read(agentProvider).map((agent) => agent.id),
      unorderedEquals(['a', 'b', 'c']),
    );
    expect(container.read(textProvider).map((text) => text.id), ['t']);
    expect(
      container.read(drawingProvider).elements.map((drawing) => drawing.id),
      ['d'],
    );
  });

  test('an item that leaves the page leaves the selection', () {
    final container = _container();
    container.read(agentProvider.notifier).fromHive([
      _agent('a', const Offset(10, 10)),
      _agent('b', const Offset(20, 20)),
    ]);
    container.read(canvasSelectionProvider.notifier).select([_a, _b]);

    container.read(agentProvider.notifier).removeAgentAsAction('a');

    expect(container.read(canvasSelectionProvider), {_b});
  });

  test('a tool that puts the page out of reach clears the selection', () {
    for (final tool in [
      InteractionState.drawing,
      InteractionState.erasing,
      InteractionState.lineUpPlacing,
    ]) {
      final container = _container();
      container
          .read(agentProvider.notifier)
          .fromHive([_agent('a', const Offset(10, 10))]);
      container.read(canvasSelectionProvider.notifier).select([_a]);

      container.read(interactionStateProvider.notifier).update(tool);

      expect(container.read(canvasSelectionProvider), isEmpty, reason: '$tool');
    }
  });

  test('a tool panel keeps the selection, open or closed', () {
    final container = _container();
    container
        .read(agentProvider.notifier)
        .fromHive([_agent('a', const Offset(10, 10))]);
    container.read(canvasSelectionProvider.notifier).select([_a]);
    final tools = container.read(interactionStateProvider.notifier);

    for (final tool in [
      InteractionState.visionCone,
      InteractionState.customShapes,
      InteractionState.textTools,
      InteractionState.roleIcons,
      InteractionState.navigation,
    ]) {
      tools.update(tool);
      expect(container.read(canvasSelectionProvider), {_a}, reason: '$tool');
    }
  });

  test('an end that stops being placed leaves the selection', () {
    final container = _container();
    final lineUps = container.read(lineUpProvider.notifier);
    container
        .read(interactionStateProvider.notifier)
        .update(InteractionState.lineUpPlacing);
    lineUps.setDraftAgent(_agent('draft', const Offset(10, 10)));
    const end = (kind: SelectableKind.lineupEnd, id: 'draft');
    container.read(canvasSelectionProvider.notifier).select([end]);

    lineUps.updateDraftAgentPosition(const Offset(20, 20));
    expect(container.read(canvasSelectionProvider), {end});

    lineUps.setDraftAgent(_agent('other', const Offset(10, 10)));
    expect(container.read(canvasSelectionProvider), isEmpty);
  });

  test('select all takes every item on the page, toggle takes one back', () {
    final container = _container();
    container.read(agentProvider.notifier).fromHive([
      _agent('a', const Offset(10, 10)),
      _agent('b', const Offset(20, 20)),
    ]);
    container.read(drawingProvider.notifier).fromHive([_line('d')]);
    final selection = container.read(canvasSelectionProvider.notifier);

    selection.selectAll();
    selection.toggle(_a);

    expect(container.read(canvasSelectionProvider), {
      _b,
      (kind: SelectableKind.drawing, id: 'd'),
    });
  });

  test('moving a selection moves agents and drawings, and undoes in one step',
      () {
    final container = _container();
    container.read(agentProvider.notifier).fromHive([
      _agent('a', const Offset(100, 100)),
      _agent('b', const Offset(300, 300)),
    ]);
    container.read(drawingProvider.notifier).fromHive([_line('d')]);
    final selection = container.read(canvasSelectionProvider.notifier);

    selection.select([_a, (kind: SelectableKind.drawing, id: 'd')]);
    selection.moveItems({'a', 'd'}, const Offset(50, 20));

    Offset agentAt(String id) => container
        .read(agentProvider)
        .firstWhere((agent) => agent.id == id)
        .position;
    Line line() => container.read(drawingProvider).elements.single as Line;
    expect(agentAt('a'), const Offset(150, 120));
    expect(agentAt('b'), const Offset(300, 300));
    expect(line().lineStart, const Offset(150, 120));

    container.read(actionProvider.notifier).undoAction();

    expect(agentAt('a'), const Offset(100, 100));
    expect(line().lineStart, const Offset(100, 100));
  });
}
