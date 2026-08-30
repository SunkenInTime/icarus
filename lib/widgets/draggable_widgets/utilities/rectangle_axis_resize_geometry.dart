import 'dart:math' as math;

import 'package:flutter/material.dart';

enum RectangleResizeSide { left, right, top, bottom }

@immutable
class RectangleAxisResizeGeometry {
  const RectangleAxisResizeGeometry({
    required this.size,
    required this.topLeft,
  });

  /// Rectangle size in the same coordinate space as [topLeft].
  final Size size;

  /// Unrotated layout top-left after the resize.
  final Offset topLeft;
}

/// Resizes one rectangle axis while keeping the opposite edge stationary.
///
/// All positions and sizes use one uniformly scaled coordinate space, such as
/// global logical pixels. [pointerDelta] is projected into the rectangle's
/// rotated local axes before the affected dimension is changed.
RectangleAxisResizeGeometry calculateRectangleAxisResize({
  required RectangleResizeSide side,
  required Offset pointerDelta,
  required Offset fixedEdgeCenter,
  required double rotation,
  required Size startingSize,
  required Size minimumSize,
  required Size maximumSize,
}) {
  final cosRotation = math.cos(rotation);
  final sinRotation = math.sin(rotation);
  final localDelta = Offset(
    (pointerDelta.dx * cosRotation) + (pointerDelta.dy * sinRotation),
    (-pointerDelta.dx * sinRotation) + (pointerDelta.dy * cosRotation),
  );

  var length = startingSize.width;
  var width = startingSize.height;
  switch (side) {
    case RectangleResizeSide.left:
      length -= localDelta.dx;
      break;
    case RectangleResizeSide.right:
      length += localDelta.dx;
      break;
    case RectangleResizeSide.top:
      width -= localDelta.dy;
      break;
    case RectangleResizeSide.bottom:
      width += localDelta.dy;
      break;
  }
  length = length.clamp(minimumSize.width, maximumSize.width).toDouble();
  width = width.clamp(minimumSize.height, maximumSize.height).toDouble();
  final size = Size(length, width);

  final fixedEdge = switch (side) {
    RectangleResizeSide.left => const Offset(1, 0.5),
    RectangleResizeSide.right => const Offset(0, 0.5),
    RectangleResizeSide.top => const Offset(0.5, 1),
    RectangleResizeSide.bottom => const Offset(0.5, 0),
  };
  final fixedFromCenter = Offset(
    (fixedEdge.dx - 0.5) * length,
    (fixedEdge.dy - 0.5) * width,
  );
  final rotatedFixedFromCenter = Offset(
    (fixedFromCenter.dx * cosRotation) - (fixedFromCenter.dy * sinRotation),
    (fixedFromCenter.dx * sinRotation) + (fixedFromCenter.dy * cosRotation),
  );
  final center = fixedEdgeCenter - rotatedFixedFromCenter;
  final topLeft = center - Offset(length / 2, width / 2);

  return RectangleAxisResizeGeometry(size: size, topLeft: topLeft);
}
