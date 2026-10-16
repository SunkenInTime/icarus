import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';

/// A key the user can press, drawn as a small keycap.
class KeybindBadge extends StatelessWidget {
  const KeybindBadge({super.key, required this.label, this.lit = false});

  final String label;

  /// Drawn brighter, while what the key acts on is hovered or chosen.
  final bool lit;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    return Container(
      height: 20,
      width: 20,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: theme.card,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: theme.border),
      ),
      child: AnimatedDefaultTextStyle(
        duration: const Duration(milliseconds: 150),
        style: Theme.of(context).textTheme.labelSmall!.copyWith(
              color: lit ? theme.foreground : theme.mutedForeground,
              fontWeight: FontWeight.w700,
              fontSize: 11,
              height: 1.0,
            ),
        child: Text(label, textAlign: TextAlign.center),
      ),
    );
  }
}
