import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';
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
    return const StrategyState(
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  test('preserveHistory keeps text undo/redo working across hydration',
      () async {
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

  test('switchSide leaves live and deleted drawings canonical', () {
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

    final canonicalLive =
        container.read(drawingProvider).elements.single as Line;
    final canonicalDeleted = notifier.poppedElements.single as Line;

    expect(canonicalLive.lineStart, const Offset(100, 110));
    expect(canonicalLive.lineEnd, const Offset(130, 160));
    expect(canonicalDeleted.lineStart, const Offset(10, 20));
    expect(canonicalDeleted.lineEnd, const Offset(40, 50));
  });

  test('switchSide leaves text canonical when measurement is missing', () {
    final container = _createContainer();
    final text = PlacedText(
      id: 'text-1',
      position: const Offset(10, 20),
      size: 100,
      fontSize: 20,
      sizeVersion: worldSizedMediaVersion,
    )..text = 'One line';

    container.read(textProvider.notifier).fromHive([text]);
    container.read(mapProvider.notifier).switchSide();

    expect(container.read(textProvider).single.position, text.position);
  });

  test('side spam leaves undo and redo snapshots canonical', () {
    final container = _createContainer();
    final text = PlacedText(
      id: 'history-text',
      position: const Offset(310, 420),
      sizeVersion: worldSizedMediaVersion,
    )..text = 'before';
    container.read(textProvider.notifier).fromHive([text]);
    container.read(textProvider.notifier).commitText(text.id, 'after');

    container.read(actionProvider.notifier).undoAction();
    final redoSnapshot =
        container.read(actionProvider.notifier).poppedItems.single.objectDelta!;
    expect(redoSnapshot.before!.text!.position, const Offset(310, 420));
    expect(redoSnapshot.after!.text!.position, const Offset(310, 420));

    for (var index = 0; index < 101; index++) {
      container.read(mapProvider.notifier).switchSide();
    }

    final afterSpam =
        container.read(actionProvider.notifier).poppedItems.single.objectDelta!;
    expect(afterSpam.before!.text!.position, const Offset(310, 420));
    expect(afterSpam.after!.text!.position, const Offset(310, 420));
    container.read(actionProvider.notifier).redoAction();
    expect(container.read(textProvider).single.text, 'after');
    expect(
      container.read(textProvider).single.position,
      const Offset(310, 420),
    );
  });
}
