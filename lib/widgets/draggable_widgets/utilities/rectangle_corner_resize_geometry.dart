import 'dart:math' as math;

import 'package:flutter/material.dart';

@immutable
class RectangleCornerResizeGeometry {
  const RectangleCornerResizeGeometry({
    required this.size,
    required this.topLeft,
  });

  /// Rectangle size in the same coordinate space as the pointer inputs.
  final Size size;

  /// Unrotated top-left in the same coordinate space as the pointer inputs.
  final Offset topLeft;
}

/// Resolves a corner resize while keeping the diagonally opposite corner
/// fixed. Pointer and result coordinates may be global screen coordinates or
/// any other uniformly scaled coordinate space.
RectangleCornerResizeGeometry calculateRectangleCornerResize({
  required Offset draggedCorner,
  required Offset pointer,
  required Offset fixedCorner,
  required double rotation,
  required Size minimumSize,
  required Size maximumSize,
}) {
  assert(
    (draggedCorner.dx == 0 || draggedCorner.dx == 1) &&
        (draggedCorner.dy == 0 || draggedCorner.dy == 1),
    'draggedCorner must use normalized 0/1 coordinates.',
  );

  final pointerFromFixed = pointer - fixedCorner;
  final cosRotation = math.cos(rotation);
  final sinRotation = math.sin(rotation);
  final unrotatedPointerDelta = Offset(
    (pointerFromFixed.dx * cosRotation) + (pointerFromFixed.dy * sinRotation),
    (-pointerFromFixed.dx * sinRotation) + (pointerFromFixed.dy * cosRotation),
  );
  final lengthDirection = draggedCorner.dx == 1 ? 1.0 : -1.0;
  final widthDirection = draggedCorner.dy == 1 ? 1.0 : -1.0;
  final length = (unrotatedPointerDelta.dx * lengthDirection)
      .clamp(minimumSize.width, maximumSize.width)
      .toDouble();
  final width = (unrotatedPointerDelta.dy * widthDirection)
      .clamp(minimumSize.height, maximumSize.height)
      .toDouble();
  final size = Size(length, width);

  final fixedCornerNormalized = Offset(
    1 - draggedCorner.dx,
    1 - draggedCorner.dy,
  );
  final fixedFromCenter = Offset(
    (fixedCornerNormalized.dx - 0.5) * length,
    (fixedCornerNormalized.dy - 0.5) * width,
  );
  final rotatedFixedFromCenter = Offset(
    (fixedFromCenter.dx * cosRotation) - (fixedFromCenter.dy * sinRotation),
    (fixedFromCenter.dx * sinRotation) + (fixedFromCenter.dy * cosRotation),
  );
  final center = fixedCorner - rotatedFixedFromCenter;

  return RectangleCornerResizeGeometry(
    size: size,
    topLeft: center - Offset(length / 2, width / 2),
  );
}
