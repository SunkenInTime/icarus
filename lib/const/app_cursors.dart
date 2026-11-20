import 'package:custom_mouse_cursor/custom_mouse_cursor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';

CustomMouseCursor? shapeRotationCursor;
CustomMouseCursor? activeShapeRotationCursor;

bool get _customCursorsSupported =>
    kIsWeb || defaultTargetPlatform != TargetPlatform.linux;

Future<CustomMouseCursor?> iconCursor(
  IconData icon, {
  required double size,
  required int hotX,
  required int hotY,
  required Color color,
  List<Shadow>? shadows,
}) async {
  if (!_customCursorsSupported) return null;
  return CustomMouseCursor.icon(
    icon,
    size: size,
    hotX: hotX,
    hotY: hotY,
    color: color,
    shadows: shadows,
  );
}

Future<void> initializeShapeRotationCursors() async {
  shapeRotationCursor = await iconCursor(
    Icons.rotate_right_rounded,
    size: 24,
    hotX: 12,
    hotY: 12,
    color: Colors.white,
    shadows: const [
      Shadow(color: Colors.black87, blurRadius: 3),
    ],
  );
  activeShapeRotationCursor = await iconCursor(
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
