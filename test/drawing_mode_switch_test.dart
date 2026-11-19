import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/traversal_speed.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';

void main() {
  late ProviderContainer container;
  late CoordinateSystem coordinates;

  setUp(() {
    coordinates = CoordinateSystem(playAreaSize: const Size(1351, 760));
    container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(interactionStateProvider.notifier)
        .update(InteractionState.drawing);
  });

  const from = Offset(100, 100), to = Offset(300, 220);

  /// Leaves the pen mid-drag, as pressing a tool's key does.
  void switchTool() => container
      .read(interactionStateProvider.notifier)
      .update(InteractionState.navigation);

  final shapes = <String, void Function(DrawingProvider)>{
    'a line': (drawing) => drawing
      ..startLine(
          from,
          coordinates,
          Colors.white,
          Settings.defaultStrokeThickness,
          false,
          false,
          false,
          TraversalSpeed.defaultProfile)
      ..updateCurrentLine(to, coordinates),
    'a rectangle': (drawing) => drawing
      ..startRectangle(from, coordinates, Colors.white,
          Settings.defaultStrokeThickness, false)
      ..updateRectangle(to, coordinates),
    'an ellipse': (drawing) => drawing
      ..startEllipse(from, coordinates, Colors.white,
          Settings.defaultStrokeThickness, false)
      ..updateEllipse(to, coordinates),
    'a freehand stroke': (drawing) => drawing
      ..startFreeDrawing(
          from,
          coordinates,
          Colors.white,
          Settings.defaultStrokeThickness,
          false,
          false,
          false,
          TraversalSpeed.defaultProfile)
      ..updateFreeDrawing(to, coordinates),
  };

  for (final MapEntry(key: name, value: draw) in shapes.entries) {
    test('switching tools half way through $name keeps it and switches', () {
      draw(container.read(drawingProvider.notifier));
      expect(container.read(drawingProvider).currentElement, isNotNull);

      switchTool();

      expect(
        container.read(interactionStateProvider),
        InteractionState.navigation,
      );
      final state = container.read(drawingProvider);
      // Nothing is left under the pointer to block the next drawing,
      expect(state.currentElement, isNull);
      // and what was drawn so far is on the page.
      expect(state.elements, hasLength(1));
      final (start, end) = switch (state.elements.single) {
        final Line line => (line.lineStart, line.lineEnd),
        final RectangleDrawing shape => (shape.start, shape.end),
        final EllipseDrawing shape => (shape.start, shape.end),
        final FreeDrawing stroke => (
            stroke.listOfPoints.first,
            stroke.listOfPoints.last
          ),
        _ => throw StateError('unknown drawing'),
      };
      expect(coordinates.coordinateToScreen(start).dx, closeTo(from.dx, 1e-6));
      expect(coordinates.coordinateToScreen(end).dy, closeTo(to.dy, 1e-6));
    });
  }
}
