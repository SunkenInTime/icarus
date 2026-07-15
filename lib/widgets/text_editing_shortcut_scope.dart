import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/shortcut_info.dart';
import 'package:icarus/providers/user_preferences_provider.dart';

class TextEditingShortcutScope extends ConsumerWidget {
  const TextEditingShortcutScope({
    super.key,
    required this.child,
    this.extraShortcuts = const {},
  });

  final Widget child;
  final Map<ShortcutActivator, Intent> extraShortcuts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final customShortcutBindings =
        Hive.isBoxOpen(HiveBoxNames.appPreferencesBox)
            ? ref.watch(appPreferencesProvider).customShortcutBindings
            : const <String, String>{};

    // Shortcut priority follows widget nesting from the focused field out:
    // field-specific commands, native text editing, then app shortcut blockers.
    final textField = DefaultTextEditingShortcuts(
      child: extraShortcuts.isEmpty
          ? child
          : Shortcuts(
              shortcuts: extraShortcuts,
              child: child,
            ),
    );

    return Shortcuts(
      shortcuts: {
        ...ShortcutInfo.textEditingOverridesFor(
          customShortcutBindings,
        ),
      },
      child: textField,
    );
  }
}
