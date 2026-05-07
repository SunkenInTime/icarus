import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
    return Shortcuts(
      shortcuts: {
        ...ShortcutInfo.textEditingOverridesFor(
          ref.watch(appPreferencesProvider).customShortcutBindings,
        ),
        ...extraShortcuts,
      },
      child: child,
    );
  }
}
