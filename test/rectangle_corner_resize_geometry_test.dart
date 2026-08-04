import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/rectangle_corner_resize_geometry.dart';

class _NoopStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() {
    return StrategyState(
      isSaved: true,
      stratName: null,
      id: 'corner-resize-test',
      storageDirectory: null,
      activePageId: null,
    );
  }

  @override
  void setUnsaved() {
    state = state.copyWith(isSaved: false);
  }
}

void main() {
  const corners = [
    Offset(0, 0),
    Offset(1, 0),
    Offset(0, 1),
    Offset(1, 1),
  ];

  test('each corner resize keeps its opposite corner fixed when rotated', () {
    const originalTopLeft = Offset(120, 90);
    const originalSize = Size(220, 110);
    const nextSize = Size(280, 145);
    const rotation = math.pi / 6;

    for (final draggedCorner in corners) {
      final fixedCorner = _globalCorner(
        topLeft: originalTopLeft,
        size: originalSize,
        corner: Offset(1 - draggedCorner.dx, 1 - draggedCorner.dy),
        rotation: rotation,
      );
      final pointer = _draggedCornerForSize(
        fixedCorner: fixedCorner,
        draggedCorner: draggedCorner,
        size: nextSize,
        rotation: rotation,
      );

      final result = calculateRectangleCornerResize(
        draggedCorner: draggedCorner,
        pointer: pointer,
        fixedCorner: fixedCorner,
        rotation: rotation,
        minimumSize: const Size(10, 10),
        maximumSize: const Size(500, 500),
      );

      expect(result.size.width, closeTo(nextSize.width, 0.0001));
      expect(result.size.height, closeTo(nextSize.height, 0.0001));
      final anchoredCorner = _globalCorner(
        topLeft: result.topLeft,
        size: result.size,
        corner: Offset(1 - draggedCorner.dx, 1 - draggedCorner.dy),
        rotation: rotation,
      );
      expect(anchoredCorner.dx, closeTo(fixedCorner.dx, 0.0001));
      expect(anchoredCorner.dy, closeTo(fixedCorner.dy, 0.0001));
    }
  });

  test('minimum size clamp does not let a corner cross its anchor', () {
    const fixedCorner = Offset(300, 240);

    final result = calculateRectangleCornerResize(
      draggedCorner: const Offset(0, 0),
      pointer: const Offset(400, 340),
      fixedCorner: fixedCorner,
      rotation: 0,
      minimumSize: const Size(60, 40),
      maximumSize: const Size(500, 500),
    );

    expect(result.size, const Size(60, 40));
    expect(result.topLeft, const Offset(240, 200));
  });

  test('maximum size clamp preserves a rotated fixed corner', () {
    const draggedCorner = Offset(1, 1);
    const fixedCorner = Offset(80, 70);
    const rotation = math.pi / 4;

    final result = calculateRectangleCornerResize(
      draggedCorner: draggedCorner,
      pointer: _draggedCornerForSize(
        fixedCorner: fixedCorner,
        draggedCorner: draggedCorner,
        size: const Size(900, 900),
        rotation: rotation,
      ),
      fixedCorner: fixedCorner,
      rotation: rotation,
      minimumSize: const Size(10, 10),
      maximumSize: const Size(250, 120),
    );

    expect(result.size, const Size(250, 120));
    final anchoredCorner = _globalCorner(
      topLeft: result.topLeft,
      size: result.size,
      corner: const Offset(0, 0),
      rotation: rotation,
    );
    expect(anchoredCorner.dx, closeTo(fixedCorner.dx, 0.0001));
    expect(anchoredCorner.dy, closeTo(fixedCorner.dy, 0.0001));
  });

  test('position and size commit as one undoable geometry edit', () {
    final container = ProviderContainer(
      overrides: [
        strategyProvider.overrideWith(_NoopStrategyProvider.new),
      ],
    );
    addTearDown(container.dispose);
    final utility = PlacedUtility(
      type: UtilityType.customRectangle,
      position: const Offset(100, 120),
      id: 'rectangle',
      customWidth: 8,
      customLength: 16,
      customColorValue: 0xff8b5cf6,
      customOpacityPercent: 40,
    );
    container.read(utilityProvider.notifier).fromHive([utility]);

    container.read(utilityProvider.notifier).updateCustomShapeGeometry(
          id: utility.id,
          position: const Offset(72, 88),
          widthMeters: 12,
          lengthMeters: 22,
        );

    var resized = container.read(utilityProvider).single;
    expect(resized.position, const Offset(72, 88));
    expect(resized.customWidth, 12);
    expect(resized.customLength, 22);
    expect(container.read(actionProvider), hasLength(1));

    container.read(actionProvider.notifier).undoAction();
    var restored = container.read(utilityProvider).single;
    expect(restored.position, const Offset(100, 120));
    expect(restored.customWidth, 8);
    expect(restored.customLength, 16);

    container.read(actionProvider.notifier).redoAction();
    resized = container.read(utilityProvider).single;
    expect(resized.position, const Offset(72, 88));
    expect(resized.customWidth, 12);
    expect(resized.customLength, 22);
  });
}

Offset _draggedCornerForSize({
  required Offset fixedCorner,
  required Offset draggedCorner,
  required Size size,
  required double rotation,
}) {
  final localDelta = Offset(
    size.width * (draggedCorner.dx == 1 ? 1 : -1),
    size.height * (draggedCorner.dy == 1 ? 1 : -1),
  );
  return fixedCorner + _rotate(localDelta, rotation);
}

Offset _globalCorner({
  required Offset topLeft,
  required Size size,
  required Offset corner,
  required double rotation,
}) {
  final center = topLeft + Offset(size.width / 2, size.height / 2);
  final fromCenter = Offset(
    (corner.dx - 0.5) * size.width,
    (corner.dy - 0.5) * size.height,
  );
  return center + _rotate(fromCenter, rotation);
}

Offset _rotate(Offset value, double rotation) {
  return Offset(
    (value.dx * math.cos(rotation)) - (value.dy * math.sin(rotation)),
    (value.dx * math.sin(rotation)) + (value.dy * math.cos(rotation)),
  );
}
