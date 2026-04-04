import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

class _NoopStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() {
    return StrategyState(
      strategyId: 'test-strategy',
      strategyName: 'Test Strategy',
      source: StrategySource.local,
      storageDirectory: null,
      isOpen: true,
    );
  }

  @override
  void setUnsaved() {
    state = state.copyWith(isOpen: true);
  }
}

ProviderContainer _createContainer() {
  final container = ProviderContainer(
    overrides: [
      strategyProvider.overrideWith(_NoopStrategyProvider.new),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Offset _flipPoint(Offset point) {
  final coordinateSystem = CoordinateSystem.instance;
  return Offset(
    coordinateSystem.worldNormalizedWidth - point.dx,
    coordinateSystem.normalizedHeight - point.dy,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  test('preserveHistory keeps text undo/redo working across hydration', () async {
    final container = _createContainer();
    final notifier = container.read(textProvider.notifier);

    notifier.fromHive([
      PlacedText(
        id: 'text-1',
        position: const Offset(10, 20),
      )..text = 'before',
    ]);
    notifier.commitText('text-1', 'after');

    notifier.clearAll();
    notifier.fromHive([
      PlacedText(
        id: 'text-1',
        position: const Offset(10, 20),
      )..text = 'after',
    ]);
    container.read(actionProvider.notifier).reconcileHistory();

    expect(container.read(actionProvider), hasLength(1));

    container.read(actionProvider.notifier).undoAction();
    expect(container.read(textProvider).single.text, 'before');

    container.read(actionProvider.notifier).redoAction();
    expect(container.read(textProvider).single.text, 'after');
  });

  test('non-preserved hydration clears action history', () async {
    final container = _createContainer();
    final notifier = container.read(textProvider.notifier);

    notifier.fromHive([
      PlacedText(
        id: 'text-1',
        position: const Offset(10, 20),
      )..text = 'before',
    ]);
    notifier.commitText('text-1', 'after');

    notifier.clearAll();
    notifier.fromHive(const []);
    container.read(actionProvider.notifier).clearActionHistory();

    expect(container.read(actionProvider), isEmpty);
  });

  test('switchSide mirrors live and deleted drawings', () {
    final container = _createContainer();
    final notifier = container.read(drawingProvider.notifier);

    final deletedLine = Line(
      id: 'deleted-line',
      lineStart: const Offset(10, 20),
      lineEnd: const Offset(40, 50),
      color: Colors.red,
      isDotted: false,
      hasArrow: false,
    );
    final liveLine = Line(
      id: 'live-line',
      lineStart: const Offset(100, 110),
      lineEnd: const Offset(130, 160),
      color: Colors.blue,
      isDotted: false,
      hasArrow: false,
    );

    notifier.fromHive([deletedLine, liveLine]);
    notifier.deleteDrawing(0);

    container.read(mapProvider.notifier).switchSide();

    final flippedLive = container.read(drawingProvider).elements.single as Line;
    final flippedDeleted = notifier.poppedElements.single as Line;

    expect(flippedLive.lineStart, _flipPoint(const Offset(100, 110)));
    expect(flippedLive.lineEnd, _flipPoint(const Offset(130, 160)));
    expect(flippedDeleted.lineStart, _flipPoint(const Offset(10, 20)));
    expect(flippedDeleted.lineEnd, _flipPoint(const Offset(40, 50)));
  });
}
