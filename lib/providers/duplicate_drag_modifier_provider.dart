import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final duplicateDragModifierProvider =
    NotifierProvider<DuplicateDragModifierNotifier, bool>(
      DuplicateDragModifierNotifier.new,
    );

class DuplicateDragModifierNotifier extends Notifier<bool> {
  final Set<LogicalKeyboardKey> _pressedModifiers = <LogicalKeyboardKey>{};

  @override
  bool build() {
    _pressedModifiers.clear();
    return false;
  }

  void handleKeyEvent(KeyEvent event) {
    final normalizedKey = _normalizedModifierKey(event.logicalKey);
    if (normalizedKey == null) return;

    if (event is KeyUpEvent) {
      _pressedModifiers.remove(normalizedKey);
    } else {
      _pressedModifiers.add(normalizedKey);
    }

    final isPressed = _pressedModifiers.isNotEmpty;
    if (state != isPressed) {
      state = isPressed;
    }
  }

  void clear() {
    _pressedModifiers.clear();
    if (state) {
      state = false;
    }
  }

  LogicalKeyboardKey? _normalizedModifierKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.control ||
        key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight) {
      return LogicalKeyboardKey.control;
    }

    if (key == LogicalKeyboardKey.meta ||
        key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight) {
      return LogicalKeyboardKey.meta;
    }

    return null;
  }
}
