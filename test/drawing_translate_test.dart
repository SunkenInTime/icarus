import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/field_merge.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/bounding_box.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

class _NoopStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() {
    return const StrategyState(
      strategyId: 'drawing-translate-test',
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
  return container;
}

const _delta = Offset(15, -5);

Line _line() => Line(
      id: 'line',
      lineStart: const Offset(100, 100),
      lineEnd: const Offset(200, 160),
      color: Colors.red,
      boundingBox: BoundingBox(
        min: const Offset(100, 100),
        max: const Offset(200, 160),
      ),
      isDotted: false,
      hasArrow: true,
    );

RectangleDrawing _rectangle() => RectangleDrawing(
      id: 'rectangle',
      start: const Offset(400, 300),
      end: const Offset(300, 250),
      color: Colors.blue,
      boundingBox: BoundingBox(
        min: const Offset(300, 250),
        max: const Offset(400, 300),
      ),
      isDotted: true,
      hasArrow: false,
    );

EllipseDrawing _ellipse() => EllipseDrawing(
      id: 'ellipse',
      start: const Offset(500, 500),
      end: const Offset(560, 540),
      color: Colors.green,
      boundingBox: BoundingBox(
        min: const Offset(500, 500),
        max: const Offset(560, 540),
      ),
      isDotted: false,
      hasArrow: false,
    );

FreeDrawing _free({List<Offset>? points}) {
  final listOfPoints =
      points ?? const [Offset(600, 600), Offset(640, 620), Offset(700, 610)];
  return FreeDrawing(
    id: 'free',
    listOfPoints: [...listOfPoints],
    color: Colors.white,
    boundingBox: BoundingBox(
      min: const Offset(600, 600),
      max: const Offset(700, 620),
    ),
    isDotted: false,
    hasArrow: false,
  );
}

Line _untouched() => Line(
      id: 'untouched',
      lineStart: const Offset(50, 50),
      lineEnd: const Offset(60, 60),
      color: Colors.yellow,
      boundingBox: BoundingBox(
        min: const Offset(50, 50),
        max: const Offset(60, 60),
      ),
      isDotted: false,
      hasArrow: false,
    );

List<DrawingElement> _page() =>
    [_line(), _rectangle(), _ellipse(), _free(), _untouched()];

const _moving = {'line', 'rectangle', 'ellipse', 'free'};

/// Every drawing as saves and live sync write it.
String _saved(ProviderContainer container) =>
    DrawingProvider.objectToJson(container.read(drawingProvider).elements);

DrawingElement _drawing(ProviderContainer container, String id) =>
    container.read(drawingProvider).elements.singleWhere((d) => d.id == id);

/// The drawings as a teammate's change brings them back from the server.
void _mergeFromServer(
  ProviderContainer container,
  List<DrawingElement> incoming,
) {
  container.read(drawingProvider.notifier).mergeRemote(
      [for (final drawing in incoming) cloneDrawingElement(drawing)],
      (_) => false);
}

/// The cloud payload live sync builds for [drawing].
CloudPayload _cloudPayload(DrawingElement drawing) {
  final encoded = jsonDecode(DrawingProvider.objectToJson([drawing])) as List;
  return cloudElementPayload(
    kind: 'drawing',
    data: Map<String, dynamic>.from(encoded.single as Map)
      ..putIfAbsent('elementType', () => 'drawing'),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => CoordinateSystem(playAreaSize: const Size(1920, 1080)));

  test('moves every point of each drawing kind, keeping the stack order', () {
    final container = _container();
    final drawings = container.read(drawingProvider.notifier)
      ..fromHive(_page());

    drawings.translateDrawings(_moving, _delta);

    final elements = container.read(drawingProvider).elements;
    expect(elements.map((d) => d.id),
        ['line', 'rectangle', 'ellipse', 'free', 'untouched']);

    final line = elements[0] as Line;
    expect(line.lineStart, const Offset(115, 95));
    expect(line.lineEnd, const Offset(215, 155));
    expect(line.boundingBox!.min, const Offset(115, 95));
    expect(line.boundingBox!.max, const Offset(215, 155));
    expect(line.colorValue, Colors.red.toARGB32());
    expect(line.hasArrow, isTrue);

    final rectangle = elements[1] as RectangleDrawing;
    expect(rectangle.start, const Offset(415, 295));
    expect(rectangle.end, const Offset(315, 245));
    expect(rectangle.boundingBox!.min, const Offset(315, 245));
    expect(rectangle.boundingBox!.max, const Offset(415, 295));
    expect(rectangle.isDotted, isTrue);

    final ellipse = elements[2] as EllipseDrawing;
    expect(ellipse.start, const Offset(515, 495));
    expect(ellipse.end, const Offset(575, 535));
    expect(ellipse.boundingBox!.min, const Offset(515, 495));
    expect(ellipse.boundingBox!.max, const Offset(575, 535));

    final free = elements[3] as FreeDrawing;
    const movedPoints = [
      Offset(615, 595),
      Offset(655, 615),
      Offset(715, 605),
    ];
    expect(free.listOfPoints, movedPoints);
    expect(free.boundingBox!.min, const Offset(615, 595));
    expect(free.boundingBox!.max, const Offset(715, 615));
    expect(free.cachedPolylineLengthUnits,
        closeTo(_free().cachedPolylineLengthUnits, 1e-9));
    // The path on screen is the one a stroke drawn there would get.
    final drawnThere = _free(points: movedPoints)
      ..rebuildPath(CoordinateSystem.instance);
    expect(free.path.getBounds(), drawnThere.path.getBounds());

    expect(elements[4].boundingBox!.min, const Offset(50, 50));
    expect(identical(elements[4], _drawing(container, 'untouched')), isTrue);
  });

  test('the eraser finds a moved drawing where it now is', () {
    final container = _container();
    final drawings = container.read(drawingProvider.notifier)
      ..fromHive([_line()]);

    drawings.translateDrawings({'line'}, const Offset(0, 200));

    final line = _drawing(container, 'line');
    expect(isNearDrawing(line, const Offset(150, 330), 2), isTrue);
    expect(isNearDrawing(line, const Offset(150, 130), 2), isFalse);
  });

  test('undo puts back the exact geometry and redo moves it again', () {
    final container = _container();
    final drawings = container.read(drawingProvider.notifier)
      ..fromHive(_page());
    final history = container.read(actionProvider.notifier);
    final before = _saved(container);

    drawings.translateDrawings(_moving, const Offset(0.1, 0.2));
    final after = _saved(container);
    expect(after, isNot(before));

    for (var step = 0; step < _moving.length; step++) {
      history.undoAction();
    }
    expect(_saved(container), before);
    expect(container.read(actionProvider), isEmpty);
    final free = _drawing(container, 'free') as FreeDrawing;
    expect(
      free.path.getBounds(),
      (_free()..rebuildPath(CoordinateSystem.instance)).path.getBounds(),
    );

    for (var step = 0; step < _moving.length; step++) {
      history.redoAction();
    }
    expect(_saved(container), after);
  });

  test('moved with an agent in one transaction, both undo as one step', () {
    final container = _container();
    container.read(agentProvider.notifier).fromHive([
      PlacedAgent(
        id: 'agent',
        type: AgentType.jett,
        position: const Offset(300, 300),
      ),
    ]);
    final drawings = container.read(drawingProvider.notifier)
      ..fromHive(_page());
    final history = container.read(actionProvider.notifier);
    final drawingsBefore = _saved(container);

    history.performTransaction(
      groups: const [ActionGroup.agent, ActionGroup.drawing],
      mutation: () {
        container
            .read(agentProvider.notifier)
            .updatePosition(const Offset(315, 295), 'agent');
        drawings.translateDrawings(_moving, _delta);
      },
    );
    final drawingsAfter = _saved(container);
    expect(container.read(actionProvider), hasLength(1));

    history.undoAction();
    expect(
        container.read(agentProvider).single.position, const Offset(300, 300));
    expect(_saved(container), drawingsBefore);
    expect(container.read(actionProvider), isEmpty);

    history.redoAction();
    expect(
        container.read(agentProvider).single.position, const Offset(315, 295));
    expect(_saved(container), drawingsAfter);
  });

  group('after a teammate changed the page', () {
    test('undo leaves a drawing they deleted deleted', () {
      final container = _container();
      container.read(agentProvider.notifier).fromHive([
        PlacedAgent(
          id: 'agent',
          type: AgentType.jett,
          position: const Offset(300, 300),
        ),
      ]);
      final drawings = container.read(drawingProvider.notifier)
        ..fromHive([_line(), _untouched()]);
      final history = container.read(actionProvider.notifier);

      history.performTransaction(
        groups: const [ActionGroup.agent, ActionGroup.drawing],
        mutation: () {
          container
              .read(agentProvider.notifier)
              .updatePosition(const Offset(315, 295), 'agent');
          drawings.translateDrawings({'line'}, _delta);
        },
      );
      _mergeFromServer(container, [_untouched()]);

      history.undoAction();
      expect(container.read(drawingProvider).elements.map((d) => d.id),
          ['untouched']);
      expect(container.read(agentProvider).single.position,
          const Offset(300, 300));

      history.redoAction();
      expect(container.read(drawingProvider).elements.map((d) => d.id),
          ['untouched']);
      expect(container.read(agentProvider).single.position,
          const Offset(315, 295));
    });

    test('a move of a drawing they deleted leaves history when reconciled', () {
      final container = _container();
      final drawings = container.read(drawingProvider.notifier)
        ..fromHive([_line(), _untouched()]);
      final history = container.read(actionProvider.notifier);

      drawings.translateDrawings({'line'}, _delta);
      drawings.translateDrawings({'untouched'}, _delta);
      _mergeFromServer(container, [_drawing(container, 'untouched')]);
      history.reconcileHistory();

      final steps = container.read(actionProvider);
      expect(steps.map((step) => step.id), ['untouched']);
    });

    test('undo keeps the colour they gave the drawing', () {
      final container = _container();
      final drawings = container.read(drawingProvider.notifier)
        ..fromHive([_line()]);
      final history = container.read(actionProvider.notifier);

      drawings.translateDrawings({'line'}, _delta);
      final moved = _drawing(container, 'line') as Line;
      _mergeFromServer(container, [moved.copyWith(color: Colors.purple)]);

      history.undoAction();
      final line = _drawing(container, 'line') as Line;
      expect(line.lineStart, const Offset(100, 100));
      expect(line.lineEnd, const Offset(200, 160));
      expect(line.boundingBox!.min, const Offset(100, 100));
      expect(line.colorValue, Colors.purple.toARGB32());
    });

    test('undo of a move they already put back changes nothing', () {
      final container = _container();
      final drawings = container.read(drawingProvider.notifier)
        ..fromHive([_free()]);
      final history = container.read(actionProvider.notifier);

      drawings.translateDrawings({'free'}, _delta);
      _mergeFromServer(container, [_free()]);
      final putBack = _saved(container);

      history.undoAction();
      expect(_saved(container), putBack);
      expect(container.read(actionProvider), isEmpty);
      expect(history.poppedItems, isEmpty);
    });
  });

  test('a move changes only the geometry live sync merges together', () {
    final cases = <DrawingElement, List<String>>{
      _line(): ['boundingBox', 'lineEnd', 'lineStart'],
      _rectangle(): ['boundingBox', 'end', 'start'],
      _ellipse(): ['boundingBox', 'end', 'start'],
      _free(): ['boundingBox', 'listOfPoints'],
    };
    for (final MapEntry(key: drawing, value: fields) in cases.entries) {
      final container = _container();
      final drawings = container.read(drawingProvider.notifier)
        ..fromHive([drawing]);
      final before = _cloudPayload(_drawing(container, drawing.id));

      drawings.translateDrawings({drawing.id}, _delta);
      final after = _cloudPayload(_drawing(container, drawing.id));

      expect(elementMergeFields(before, after), fields,
          reason: drawing.runtimeType.toString());
    }
  });

  test('a zero move or an unknown id records nothing', () {
    final container = _container();
    final drawings = container.read(drawingProvider.notifier)
      ..fromHive([_line()]);
    final elements = container.read(drawingProvider).elements;

    drawings.translateDrawings({'line'}, Offset.zero);
    drawings.translateDrawings({'missing'}, _delta);

    expect(container.read(actionProvider), isEmpty);
    expect(
        identical(container.read(drawingProvider).elements, elements), isTrue);
  });

  test('a drawing edit round-trips through its history JSON', () {
    for (final drawing in _page()) {
      final state = ActionObjectState.drawing(drawing);
      final restored = ActionObjectState.fromJson(
        ActionObjectKind.drawing,
        state.toJson(),
      );
      expect(restored.toJson(), state.toJson());
      expect(restored.drawing.runtimeType, drawing.runtimeType);
    }
  });
}
