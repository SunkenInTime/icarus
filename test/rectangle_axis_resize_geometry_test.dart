import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/rectangle_axis_resize_geometry.dart';

class _NoopStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() {
    return StrategyState(
      isSaved: true,
      stratName: null,
      id: 'axis-resize-test',
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
  test('all four axes keep the opposite edge fixed when rotated', () {
    const originalTopLeft = Offset(120, 90);
    const originalSize = Size(220, 110);
    const rotation = math.pi / 6;

    for (final side in RectangleResizeSide.values) {
      final nextSize = switch (side) {
        RectangleResizeSide.left ||
        RectangleResizeSide.right =>
          const Size(280, 110),
        RectangleResizeSide.top ||
        RectangleResizeSide.bottom =>
          const Size(220, 145),
      };
      final fixedEdgeCenter = _globalEdgeCenter(
        topLeft: originalTopLeft,
        size: originalSize,
        side: _opposite(side),
        rotation: rotation,
      );
      final result = calculateRectangleAxisResize(
        side: side,
        pointerDelta: _pointerDeltaForSize(
          side: side,
          originalSize: originalSize,
          nextSize: nextSize,
          rotation: rotation,
        ),
        fixedEdgeCenter: fixedEdgeCenter,
        rotation: rotation,
        startingSize: originalSize,
        minimumSize: const Size(10, 10),
        maximumSize: const Size(500, 500),
      );

      expect(result.size.width, closeTo(nextSize.width, 0.0001));
      expect(result.size.height, closeTo(nextSize.height, 0.0001));
      final anchoredEdgeCenter = _globalEdgeCenter(
        topLeft: result.topLeft,
        size: result.size,
        side: _opposite(side),
        rotation: rotation,
      );
      expect(anchoredEdgeCenter.dx, closeTo(fixedEdgeCenter.dx, 0.0001));
      expect(anchoredEdgeCenter.dy, closeTo(fixedEdgeCenter.dy, 0.0001));
    }
  });

  test('minimum size clamp prevents an axis crossing its fixed edge', () {
    const fixedEdgeCenter = Offset(300, 240);

    final result = calculateRectangleAxisResize(
      side: RectangleResizeSide.left,
      pointerDelta: const Offset(500, 0),
      fixedEdgeCenter: fixedEdgeCenter,
      rotation: 0,
      startingSize: const Size(200, 80),
      minimumSize: const Size(60, 40),
      maximumSize: const Size(500, 500),
    );

    expect(result.size, const Size(60, 80));
    expect(result.topLeft, const Offset(240, 200));
  });

  test('maximum size clamp preserves a rotated fixed edge', () {
    const originalSize = Size(200, 80);
    const originalTopLeft = Offset(90, 70);
    const rotation = math.pi / 4;
    final fixedEdgeCenter = _globalEdgeCenter(
      topLeft: originalTopLeft,
      size: originalSize,
      side: RectangleResizeSide.left,
      rotation: rotation,
    );

    final result = calculateRectangleAxisResize(
      side: RectangleResizeSide.right,
      pointerDelta: _rotate(const Offset(900, 0), rotation),
      fixedEdgeCenter: fixedEdgeCenter,
      rotation: rotation,
      startingSize: originalSize,
      minimumSize: const Size(10, 10),
      maximumSize: const Size(250, 120),
    );

    expect(result.size, const Size(250, 80));
    final anchoredEdgeCenter = _globalEdgeCenter(
      topLeft: result.topLeft,
      size: result.size,
      side: RectangleResizeSide.left,
      rotation: rotation,
    );
    expect(anchoredEdgeCenter.dx, closeTo(fixedEdgeCenter.dx, 0.0001));
    expect(anchoredEdgeCenter.dy, closeTo(fixedEdgeCenter.dy, 0.0001));
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

RectangleResizeSide _opposite(RectangleResizeSide side) => switch (side) {
      RectangleResizeSide.left => RectangleResizeSide.right,
      RectangleResizeSide.right => RectangleResizeSide.left,
      RectangleResizeSide.top => RectangleResizeSide.bottom,
      RectangleResizeSide.bottom => RectangleResizeSide.top,
    };

Offset _pointerDeltaForSize({
  required RectangleResizeSide side,
  required Size originalSize,
  required Size nextSize,
  required double rotation,
}) {
  final localDelta = switch (side) {
    RectangleResizeSide.left => Offset(originalSize.width - nextSize.width, 0),
    RectangleResizeSide.right => Offset(nextSize.width - originalSize.width, 0),
    RectangleResizeSide.top => Offset(0, originalSize.height - nextSize.height),
    RectangleResizeSide.bottom =>
      Offset(0, nextSize.height - originalSize.height),
  };
  return _rotate(localDelta, rotation);
}

Offset _globalEdgeCenter({
  required Offset topLeft,
  required Size size,
  required RectangleResizeSide side,
  required double rotation,
}) {
  final normalized = switch (side) {
    RectangleResizeSide.left => const Offset(0, 0.5),
    RectangleResizeSide.right => const Offset(1, 0.5),
    RectangleResizeSide.top => const Offset(0.5, 0),
    RectangleResizeSide.bottom => const Offset(0.5, 1),
  };
  final center = topLeft + Offset(size.width / 2, size.height / 2);
  final fromCenter = Offset(
    (normalized.dx - 0.5) * size.width,
    (normalized.dy - 0.5) * size.height,
  );
  return center + _rotate(fromCenter, rotation);
}

Offset _rotate(Offset value, double rotation) {
  return Offset(
    (value.dx * math.cos(rotation)) - (value.dy * math.sin(rotation)),
    (value.dx * math.sin(rotation)) + (value.dy * math.cos(rotation)),
  );
}
