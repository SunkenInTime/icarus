import 'package:custom_mouse_cursor/custom_mouse_cursor.dart';
import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';

CustomMouseCursor? shapeRotationCursor;
CustomMouseCursor? activeShapeRotationCursor;

Future<void> initializeShapeRotationCursors() async {
  shapeRotationCursor = await CustomMouseCursor.icon(
    Icons.rotate_right_rounded,
    size: 24,
    hotX: 12,
    hotY: 12,
    color: Colors.white,
    shadows: const [
      Shadow(color: Colors.black87, blurRadius: 3),
    ],
  );
  activeShapeRotationCursor = await CustomMouseCursor.icon(
    Icons.rotate_right_rounded,
    size: 24,
    hotX: 12,
    hotY: 12,
    color: Settings.tacticalVioletTheme.primary,
    shadows: const [
      Shadow(color: Colors.black87, blurRadius: 3),
    ],
  );
}

MouseCursor shapeRotationMouseCursor({required bool active}) {
  if (active) {
    return activeShapeRotationCursor ?? SystemMouseCursors.grabbing;
  }
  return shapeRotationCursor ?? SystemMouseCursors.grab;
}
