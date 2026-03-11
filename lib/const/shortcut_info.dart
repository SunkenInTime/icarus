import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ShortcutInfo {
  static const LogicalKeyboardKey openDeleteMenuKey = LogicalKeyboardKey.keyE;

  static final Map<ShortcutActivator, Intent> globalShortcuts = {
    LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyZ):
        const UndoActionIntent(),
    LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyZ):
        const UndoActionIntent(),
    LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyS):
        const SaveStrategyIntent(),
    LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyS):
        const SaveStrategyIntent(),
    LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyZ,
        LogicalKeyboardKey.shift): const RedoActionIntent(),
    LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyZ,
        LogicalKeyboardKey.shift): const RedoActionIntent(),
    LogicalKeySet(LogicalKeyboardKey.keyQ): const ToggleDrawingIntent(),
    LogicalKeySet(LogicalKeyboardKey.keyW): const ToggleErasingIntent(),
    LogicalKeySet(openDeleteMenuKey): const ContextualDeleteIntent(),
    LogicalKeySet(LogicalKeyboardKey.keyT): const AddedTextIntent(),
    LogicalKeySet(LogicalKeyboardKey.keyS): const NavigationActionIntent(),
    LogicalKeySet(LogicalKeyboardKey.keyR): const ToggleAgentFilterIntent(),
    LogicalKeySet(LogicalKeyboardKey.keyD): const ForwardPageIntent(),
    LogicalKeySet(LogicalKeyboardKey.keyA): const BackwardPageIntent(),
    LogicalKeySet(LogicalKeyboardKey.keyC): const AddPageIntent(),
    LogicalKeySet(LogicalKeyboardKey.keyG): const ToggleLineupIntent(),
    LogicalKeySet(LogicalKeyboardKey.f12): const OpenInAppDebugIntent(),
    LogicalKeySet(LogicalKeyboardKey.keyV, LogicalKeyboardKey.control):
        const PasteImageIntent(),
  };

  // New map to disable global shortcuts when typing
  static final Map<ShortcutActivator, Intent> textEditingOverrides = {
    // Override Ctrl+Z/Cmd+Z (let the TextField handle these)
    LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyZ):
        const DoNothingAndStopPropagationIntent(),
    LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyZ):
        const DoNothingAndStopPropagationIntent(),

    LogicalKeySet(LogicalKeyboardKey.keyT):
        const DoNothingAndStopPropagationIntent(),
    // Override Ctrl+Shift+Z/Cmd+Shift+Z
    LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyZ,
        LogicalKeyboardKey.shift): const DoNothingAndStopPropagationIntent(),
    LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyZ,
        LogicalKeyboardKey.shift): const DoNothingAndStopPropagationIntent(),
    LogicalKeySet(LogicalKeyboardKey.keyA):
        const DoNothingAndStopPropagationIntent(),
    LogicalKeySet(LogicalKeyboardKey.keyD):
        const DoNothingAndStopPropagationIntent(),
    LogicalKeySet(LogicalKeyboardKey.keyC):
        const DoNothingAndStopPropagationIntent(),
    // Override Q and W shortcuts
    LogicalKeySet(LogicalKeyboardKey.keyQ):
        const DoNothingAndStopPropagationIntent(),
    LogicalKeySet(LogicalKeyboardKey.keyW):
        const DoNothingAndStopPropagationIntent(),
    LogicalKeySet(LogicalKeyboardKey.keyE):
        const DoNothingAndStopPropagationIntent(),

    LogicalKeySet(LogicalKeyboardKey.keyS):
        const DoNothingAndStopPropagationIntent(),
    LogicalKeySet(LogicalKeyboardKey.keyR):
        const DoNothingAndStopPropagationIntent(),
    LogicalKeySet(LogicalKeyboardKey.keyG):
        const DoNothingAndStopPropagationIntent(),

    LogicalKeySet(LogicalKeyboardKey.enter): const EnterTextIntent(),
    // LogicalKeySet(LogicalKeyboardKey.keyV, LogicalKeyboardKey.control):
    //     const DoNothingAndStopPropagationIntent(),
  };
}

class PasteImageIntent extends Intent {
  const PasteImageIntent();
}

class ToggleDrawingIntent extends Intent {
  const ToggleDrawingIntent();
}

class AddedTextIntent extends Intent {
  const AddedTextIntent();
}

class ToggleErasingIntent extends Intent {
  const ToggleErasingIntent();
}

class ContextualDeleteIntent extends Intent {
  const ContextualDeleteIntent();
}

class EnterTextIntent extends Intent {
  const EnterTextIntent();
}

class UndoActionIntent extends Intent {
  const UndoActionIntent();
}

class RedoActionIntent extends Intent {
  const RedoActionIntent();
}

class SaveStrategyIntent extends Intent {
  const SaveStrategyIntent();
}

class NavigationActionIntent extends Intent {
  const NavigationActionIntent();
}

class ToggleAgentFilterIntent extends Intent {
  const ToggleAgentFilterIntent();
}

class ForwardPageIntent extends Intent {
  const ForwardPageIntent();
}

class BackwardPageIntent extends Intent {
  const BackwardPageIntent();
}

class AddPageIntent extends Intent {
  const AddPageIntent();
}

class ToggleLineupIntent extends Intent {
  const ToggleLineupIntent();
}

class OpenInAppDebugIntent extends Intent {
  const OpenInAppDebugIntent();
}
