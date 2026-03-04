import 'package:flutter/material.dart';
import 'package:icarus/const/coordinate_system.dart';

class DefaultPlacement {
  const DefaultPlacement._();

  static Offset topLeftFromSceneAnchor({
    required Offset viewportCenter,
    required Offset anchorScenePx,
  }) {
    final coordinateSystem = CoordinateSystem.instance;
    final normalizedAnchor = coordinateSystem.screenToCoordinate(anchorScenePx);
    return viewportCenter - normalizedAnchor;
  }

  static Offset topLeftFromVirtualAnchor({
    required Offset viewportCenter,
    required Offset anchorVirtual,
  }) {
    final coordinateSystem = CoordinateSystem.instance;
    final anchorScenePx = anchorVirtual.scale(
      coordinateSystem.scaleFactor,
      coordinateSystem.scaleFactor,
    );
    return topLeftFromSceneAnchor(
      viewportCenter: viewportCenter,
      anchorScenePx: anchorScenePx,
    );
  }
}
