import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum IcarusShortcutAction {
  draw,
  erase,
  addText,
  navigation,
  toggleAgentFilter,
  forwardPage,
  backwardPage,
  addPage,
  addLineup,
  openDeleteMenu,
  saveStrategy,
  pasteImage,
  openInAppDebug,
}

class IcarusKeyBinding {
  const IcarusKeyBinding({
    required this.trigger,
    this.primary = false,
    this.shift = false,
    this.alt = false,
  });

  final LogicalKeyboardKey trigger;
  final bool primary;
  final bool shift;
  final bool alt;
  static const LogicalKeyboardKey emptyTrigger = LogicalKeyboardKey(0);

  static IcarusKeyBinding? tryParse(String value) {
    final parts = value.split('+');
    if (parts.isEmpty) return null;

    var primary = false;
    var shift = false;
    var alt = false;
    int? triggerKeyId;

    for (final rawPart in parts) {
      final part = rawPart.trim();
      if (part.isEmpty) continue;
      switch (part) {
        case 'primary':
          primary = true;
        case 'shift':
          shift = true;
        case 'alt':
          alt = true;
        default:
          triggerKeyId = int.tryParse(part);
      }
    }

    if (triggerKeyId == null) return null;
    return IcarusKeyBinding(
      trigger: LogicalKeyboardKey(triggerKeyId),
      primary: primary,
      shift: shift,
      alt: alt,
    );
  }

  static IcarusKeyBinding fromPressedKeys(Set<LogicalKeyboardKey> keys) {
    final primary = keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight) ||
        keys.contains(LogicalKeyboardKey.control) ||
        keys.contains(LogicalKeyboardKey.metaLeft) ||
        keys.contains(LogicalKeyboardKey.metaRight) ||
        keys.contains(LogicalKeyboardKey.meta);
    final shift = keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight) ||
        keys.contains(LogicalKeyboardKey.shift);
    final alt = keys.contains(LogicalKeyboardKey.altLeft) ||
        keys.contains(LogicalKeyboardKey.altRight) ||
        keys.contains(LogicalKeyboardKey.alt);

    final trigger = keys.lastWhere(
      (key) => !_modifierKeys.contains(key),
      orElse: () => emptyTrigger,
    );

    return IcarusKeyBinding(
      trigger: trigger,
      primary: primary,
      shift: shift,
      alt: alt,
    );
  }

  bool get isComplete => trigger != emptyTrigger;

  String serialize() {
    final parts = <String>[
      if (primary) 'primary',
      if (shift) 'shift',
      if (alt) 'alt',
      trigger.keyId.toString(),
    ];
    return parts.join('+');
  }

  String displayLabel({TargetPlatform? platform}) {
    final resolvedPlatform = platform ?? defaultTargetPlatform;
    final primaryLabel =
        resolvedPlatform == TargetPlatform.macOS ? 'Cmd' : 'Ctrl';
    final parts = <String>[
      if (primary) primaryLabel,
      if (shift) 'Shift',
      if (alt) 'Alt',
      _displayTriggerLabel(trigger),
    ];
    return parts.join(' ');
  }

  ShortcutActivator toActivator({TargetPlatform? platform}) {
    final resolvedPlatform = platform ?? defaultTargetPlatform;
    final keys = <LogicalKeyboardKey>[
      if (primary)
        resolvedPlatform == TargetPlatform.macOS
            ? LogicalKeyboardKey.meta
            : LogicalKeyboardKey.control,
      if (shift) LogicalKeyboardKey.shift,
      if (alt) LogicalKeyboardKey.alt,
      trigger,
    ];
    return LogicalKeySet.fromSet(keys.toSet());
  }

  bool matchesSearch(String query, {TargetPlatform? platform}) {
    final normalizedQuery = ShortcutInfo.normalizeSearch(query);
    return ShortcutInfo.normalizeSearch(displayLabel(platform: platform))
        .contains(normalizedQuery);
  }

  @override
  bool operator ==(Object other) {
    return other is IcarusKeyBinding &&
        other.trigger == trigger &&
        other.primary == primary &&
        other.shift == shift &&
        other.alt == alt;
  }

  @override
  int get hashCode => Object.hash(trigger, primary, shift, alt);

  static final Set<LogicalKeyboardKey> _modifierKeys = {
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.meta,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
  };
}

class IcarusShortcutDefinition {
  const IcarusShortcutDefinition({
    required this.action,
    required this.title,
    required this.defaultBinding,
    required this.intent,
    this.searchAliases = const [],
  });

  final IcarusShortcutAction action;
  final String title;
  final IcarusKeyBinding defaultBinding;
  final Intent intent;
  final List<String> searchAliases;

  String get id => action.name;
}

class ShortcutInfo {
  static const LogicalKeyboardKey openDeleteMenuKey = LogicalKeyboardKey.keyE;

  static const editableShortcuts = [
    IcarusShortcutDefinition(
      action: IcarusShortcutAction.draw,
      title: 'Draw',
      defaultBinding: IcarusKeyBinding(trigger: LogicalKeyboardKey.keyQ),
      intent: ToggleDrawingIntent(),
    ),
    IcarusShortcutDefinition(
      action: IcarusShortcutAction.erase,
      title: 'Eraser',
      defaultBinding: IcarusKeyBinding(trigger: LogicalKeyboardKey.keyW),
      intent: ToggleErasingIntent(),
      searchAliases: ['erase'],
    ),
    IcarusShortcutDefinition(
      action: IcarusShortcutAction.addText,
      title: 'Add Text',
      defaultBinding: IcarusKeyBinding(trigger: LogicalKeyboardKey.keyT),
      intent: AddedTextIntent(),
      searchAliases: ['text'],
    ),
    IcarusShortcutDefinition(
      action: IcarusShortcutAction.navigation,
      title: 'Navigation',
      defaultBinding: IcarusKeyBinding(trigger: LogicalKeyboardKey.keyS),
      intent: NavigationActionIntent(),
      searchAliases: ['select', 'pointer'],
    ),
    IcarusShortcutDefinition(
      action: IcarusShortcutAction.toggleAgentFilter,
      title: 'Toggle Agent Filter',
      defaultBinding: IcarusKeyBinding(trigger: LogicalKeyboardKey.keyR),
      intent: ToggleAgentFilterIntent(),
      searchAliases: ['agents', 'filter'],
    ),
    IcarusShortcutDefinition(
      action: IcarusShortcutAction.forwardPage,
      title: 'Next Page',
      defaultBinding: IcarusKeyBinding(trigger: LogicalKeyboardKey.keyD),
      intent: ForwardPageIntent(),
      searchAliases: ['forward'],
    ),
    IcarusShortcutDefinition(
      action: IcarusShortcutAction.backwardPage,
      title: 'Previous Page',
      defaultBinding: IcarusKeyBinding(trigger: LogicalKeyboardKey.keyA),
      intent: BackwardPageIntent(),
      searchAliases: ['backward', 'back'],
    ),
    IcarusShortcutDefinition(
      action: IcarusShortcutAction.addPage,
      title: 'Add Page',
      defaultBinding: IcarusKeyBinding(trigger: LogicalKeyboardKey.keyC),
      intent: AddPageIntent(),
    ),
    IcarusShortcutDefinition(
      action: IcarusShortcutAction.addLineup,
      title: 'Add Lineup',
      defaultBinding: IcarusKeyBinding(trigger: LogicalKeyboardKey.keyG),
      intent: ToggleLineupIntent(),
      searchAliases: ['lineup'],
    ),
    IcarusShortcutDefinition(
      action: IcarusShortcutAction.openDeleteMenu,
      title: 'Open Delete Menu',
      defaultBinding: IcarusKeyBinding(trigger: openDeleteMenuKey),
      intent: ContextualDeleteIntent(),
      searchAliases: ['delete'],
    ),
    IcarusShortcutDefinition(
      action: IcarusShortcutAction.saveStrategy,
      title: 'Save Strategy',
      defaultBinding: IcarusKeyBinding(
        trigger: LogicalKeyboardKey.keyS,
        primary: true,
      ),
      intent: SaveStrategyIntent(),
      searchAliases: ['save'],
    ),
    IcarusShortcutDefinition(
      action: IcarusShortcutAction.pasteImage,
      title: 'Paste Image',
      defaultBinding: IcarusKeyBinding(
        trigger: LogicalKeyboardKey.keyV,
        primary: true,
      ),
      intent: PasteImageIntent(),
      searchAliases: ['paste'],
    ),
    IcarusShortcutDefinition(
      action: IcarusShortcutAction.openInAppDebug,
      title: 'Open Debug Log',
      defaultBinding: IcarusKeyBinding(trigger: LogicalKeyboardKey.f12),
      intent: OpenInAppDebugIntent(),
      searchAliases: ['debug', 'log'],
    ),
  ];

  static final Map<String, IcarusShortcutDefinition> definitionsById = {
    for (final definition in editableShortcuts) definition.id: definition,
  };

  static Map<ShortcutActivator, Intent> globalShortcutsFor(
    Map<String, String> customBindings, {
    TargetPlatform? platform,
  }) {
    return {
      _primaryActivator(LogicalKeyboardKey.keyZ, platform: platform):
          const UndoActionIntent(),
      _primaryActivator(
        LogicalKeyboardKey.keyZ,
        shift: true,
        platform: platform,
      ): const RedoActionIntent(),
      for (final definition in editableShortcuts)
        effectiveBindingFor(definition.id, customBindings)
            .toActivator(platform: platform): definition.intent,
    };
  }

  static final Map<ShortcutActivator, Intent> globalShortcuts =
      globalShortcutsFor(const {});

  // New map to disable global shortcuts when typing
  static Map<ShortcutActivator, Intent> textEditingOverridesFor(
    Map<String, String> customBindings, {
    TargetPlatform? platform,
  }) {
    return {
      _primaryActivator(LogicalKeyboardKey.keyZ, platform: platform):
          const DoNothingAndStopPropagationIntent(),
      _primaryActivator(
        LogicalKeyboardKey.keyZ,
        shift: true,
        platform: platform,
      ): const DoNothingAndStopPropagationIntent(),
      for (final definition in editableShortcuts)
        effectiveBindingFor(definition.id, customBindings).toActivator(
            platform: platform): const DoNothingAndStopPropagationIntent(),
      LogicalKeySet(LogicalKeyboardKey.enter): const EnterTextIntent(),
    };
  }

  static final Map<ShortcutActivator, Intent> textEditingOverrides =
      textEditingOverridesFor(const {});

  static IcarusKeyBinding effectiveBindingFor(
    String shortcutId,
    Map<String, String> customBindings,
  ) {
    final definition = definitionsById[shortcutId];
    final custom = customBindings[shortcutId];
    if (definition == null) {
      return const IcarusKeyBinding(trigger: IcarusKeyBinding.emptyTrigger);
    }
    if (custom == null) return definition.defaultBinding;
    return IcarusKeyBinding.tryParse(custom) ?? definition.defaultBinding;
  }

  static String displayLabelFor(
    String shortcutId,
    Map<String, String> customBindings, {
    TargetPlatform? platform,
  }) {
    return effectiveBindingFor(shortcutId, customBindings)
        .displayLabel(platform: platform);
  }

  static IcarusShortcutDefinition? findDuplicateBinding({
    required String editingShortcutId,
    required IcarusKeyBinding binding,
    required Map<String, String> customBindings,
  }) {
    for (final definition in editableShortcuts) {
      if (definition.id == editingShortcutId) continue;
      final existing = effectiveBindingFor(definition.id, customBindings);
      if (existing == binding) return definition;
    }
    return null;
  }

  static bool isDefaultBinding(
    String shortcutId,
    Map<String, String> customBindings,
  ) {
    final definition = definitionsById[shortcutId];
    if (definition == null) return true;
    return effectiveBindingFor(shortcutId, customBindings) ==
        definition.defaultBinding;
  }

  static bool matchesSearch(
    IcarusShortcutDefinition definition,
    String query,
    Map<String, String> customBindings, {
    TargetPlatform? platform,
  }) {
    final normalizedQuery = normalizeSearch(query);
    if (normalizedQuery.isEmpty) return true;
    final title = normalizeSearch(definition.title);
    final aliases = definition.searchAliases.map(normalizeSearch).join(' ');
    final binding = effectiveBindingFor(definition.id, customBindings);
    return title.contains(normalizedQuery) ||
        aliases.contains(normalizedQuery) ||
        binding.matchesSearch(query, platform: platform);
  }

  static String normalizeSearch(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[\s+\-_/]'), '')
        .replaceAll('command', 'cmd')
        .replaceAll('control', 'ctrl');
  }

  static ShortcutActivator _primaryActivator(
    LogicalKeyboardKey trigger, {
    bool shift = false,
    TargetPlatform? platform,
  }) {
    return IcarusKeyBinding(
      trigger: trigger,
      primary: true,
      shift: shift,
    ).toActivator(platform: platform);
  }
}

String _displayTriggerLabel(LogicalKeyboardKey key) {
  if (key.keyLabel.isNotEmpty) return key.keyLabel.toUpperCase();
  if (key == LogicalKeyboardKey.f12) return 'F12';
  if (key == LogicalKeyboardKey.escape) return 'Esc';
  if (key == LogicalKeyboardKey.enter) return 'Enter';
  if (key == LogicalKeyboardKey.space) return 'Space';
  if (key == LogicalKeyboardKey.tab) return 'Tab';
  if (key == LogicalKeyboardKey.backspace) return 'Backspace';
  if (key == LogicalKeyboardKey.delete) return 'Delete';
  return key.debugName ?? 'Key';
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
