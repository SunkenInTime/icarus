import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether Alt is held, which keeps a dragged item on the map. Going by this
/// rather than [HardwareKeyboard.isAltPressed] because Alt+Tab takes the key
/// up to another window: the keyboard would still say held on the way back.
final keepOnMapKeyProvider =
    NotifierProvider<KeepOnMapKeyNotifier, bool>(KeepOnMapKeyNotifier.new);

class KeepOnMapKeyNotifier extends Notifier<bool> {
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
