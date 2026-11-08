import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether Alt is held, which snaps a dragged item onto the map's lines.
/// Going by this rather than [HardwareKeyboard.isAltPressed] because Alt+Tab
/// takes the key up to another window: the keyboard would still say held on
/// the way back.
final snapToMapKeyProvider =
    NotifierProvider<SnapToMapKeyNotifier, bool>(SnapToMapKeyNotifier.new);

class SnapToMapKeyNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  static bool isAlt(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.altLeft || key == LogicalKeyboardKey.altRight;

  void handleKeyEvent(KeyEvent event) {
    if (!isAlt(event.logicalKey)) return;
    final held = HardwareKeyboard.instance.isAltPressed;
    if (state != held) state = held;
  }

  void clear() {
    if (state) state = false;
  }
}
