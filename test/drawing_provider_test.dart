import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/bounding_box.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/traversal_speed.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';

class _NoopStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() {
    return StrategyState(
      isSaved: true,
      stratName: null,
      id: 'drawing-test',
      storageDirectory: null,
      activePageId: null,
    );
  }

  @override
  void setUnsaved() {
    state = state.copyWith(isSaved: false);
  }
}

ProviderContainer _createContainer() {
  return ProviderContainer(
    overrides: [
      strategyProvider.overrideWith(_NoopStrategyProvider.new),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  group('DrawingProvider serialization', () {
    test('line JSON round-trip preserves metadata', () {
      final line = Line(
        id: 'line-1',
        lineStart: const Offset(10, 20),
        lineEnd: const Offset(30, 40),
        color: Colors.red,
        boundingBox: BoundingBox(
          min: const Offset(10, 20),
          max: const Offset(30, 40),
        ),
        isDotted: true,
        hasArrow: true,
        showTraversalTime: true,
        traversalSpeedProfile: TraversalSpeedProfile.walking,
      );

      final encoded = DrawingProvider.objectToJson([line]);
      final decodedJson = jsonDecode(encoded) as List<dynamic>;

      expect(decodedJson.single, containsPair('type', 'lineDrawing'));
      expect(decodedJson.single, containsPair('isDotted', true));
      expect(decodedJson.single, containsPair('hasArrow', true));
      expect(decodedJson.single, containsPair('showTraversalTime', true));
      expect(
        decodedJson.single,
        containsPair('traversalSpeedProfile', 'walking'),
      );

      final decoded = DrawingProvider.fromJson(encoded).single as Line;
      expect(decoded.lineStart, const Offset(10, 20));
      expect(decoded.lineEnd, const Offset(30, 40));
      expect(decoded.boundingBox!.min, const Offset(10, 20));
      expect(decoded.boundingBox!.max, const Offset(30, 40));
      expect(decoded.isDotted, isTrue);
      expect(decoded.hasArrow, isTrue);
      expect(decoded.showTraversalTime, isTrue);
      expect(decoded.traversalSpeedProfile, TraversalSpeedProfile.walking);
    });

    test('typeless line, freehand, and rectangle payloads remain importable',
        () {
      final payload = jsonEncode([
        {
          'id': 'line-legacy',
          'color': '#FFFFFFFF',
          'isDotted': true,
          'hasArrow': true,
          'lineStart': {'dx': 1.0, 'dy': 2.0},
          'lineEnd': {'dx': 3.0, 'dy': 4.0},
        },
        {
          'id': 'free-legacy',
          'color': '#FFFFFFFF',
          'isDotted': false,
          'hasArrow': false,
          'boundingBox': {
            'min': {'dx': 5.0, 'dy': 6.0},
            'max': {'dx': 7.0, 'dy': 8.0},
          },
          'listOfPoints': [
            {'dx': 5.0, 'dy': 6.0},
            {'dx': 7.0, 'dy': 8.0},
          ],
        },
        {
          'id': 'rect-legacy',
          'color': '#FFFFFFFF',
          'isDotted': true,
          'hasArrow': false,
          'start': {'dx': 9.0, 'dy': 10.0},
          'end': {'dx': 11.0, 'dy': 12.0},
        },
      ]);

      final decoded = DrawingProvider.fromJson(payload);

      expect(decoded[0], isA<Line>());
      expect(decoded[1], isA<FreeDrawing>());
      expect(decoded[2], isA<RectangleDrawing>());
    });
  });

  group('DrawingProvider line actions', () {
    test('line drawing supports undo, redo, and erase', () {
      final container = _createContainer();
      addTearDown(container.dispose);

      final drawingNotifier = container.read(drawingProvider.notifier);
      final actionNotifier = container.read(actionProvider.notifier);
      final coordinateSystem = CoordinateSystem.instance;

      drawingNotifier.startLine(
        const Offset(100, 120),
        coordinateSystem,
        Colors.white,
        true,
        true,
        true,
        TraversalSpeedProfile.brimStim,
      );
      drawingNotifier.updateCurrentLine(
        const Offset(220, 260),
        coordinateSystem,
      );
      drawingNotifier.finishCurrentLine(
        const Offset(220, 260),
        coordinateSystem,
      );

      final line = container.read(drawingProvider).elements.single as Line;
      expect(line.isDotted, isTrue);
      expect(line.hasArrow, isTrue);
      expect(line.showTraversalTime, isTrue);
      expect(line.traversalSpeedProfile, TraversalSpeedProfile.brimStim);

      actionNotifier.undoAction();
      expect(container.read(drawingProvider).elements, isEmpty);

      actionNotifier.redoAction();
      expect(container.read(drawingProvider).elements, hasLength(1));

      final restoredLine =
          container.read(drawingProvider).elements.single as Line;
      final midpoint = Offset(
        (restoredLine.lineStart.dx + restoredLine.lineEnd.dx) / 2,
        (restoredLine.lineStart.dy + restoredLine.lineEnd.dy) / 2,
      );
      drawingNotifier.onErase(midpoint);

      expect(container.read(drawingProvider).elements, isEmpty);
    });
  });
}
