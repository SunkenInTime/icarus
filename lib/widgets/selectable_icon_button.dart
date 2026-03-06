import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class SelectableIconButton extends ConsumerWidget {
  const SelectableIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.isSelected,
    this.tooltip,
    this.hoverBackgroundColor,
    this.shortcutLabel,
  });

  final bool isSelected;
  final Widget icon;
  final VoidCallback onPressed;
  final String? tooltip;
  final Color? hoverBackgroundColor;
  final String? shortcutLabel;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasShortcutLabel = shortcutLabel != null && shortcutLabel!.isNotEmpty;

    final button = ShadTooltip(
      builder: (context) => Text(tooltip ?? ''),
      child: ShadIconButton.secondary(
        padding: EdgeInsets.zero,
        icon: icon,
        backgroundColor: isSelected
            ? hoverBackgroundColor ?? Settings.tacticalVioletTheme.primary
            : null,
        hoverBackgroundColor: isSelected
            ? hoverBackgroundColor ?? Settings.tacticalVioletTheme.primary
            : null,
        onPressed: onPressed,
      ),
    );

    if (!hasShortcutLabel) return button;
    return SizedBox(
      width: 57.8,
      height: 57.8,
      child: Stack(
        children: [
          Positioned.fill(child: button),
          Positioned(
            right: 0,
            bottom: 0,
            child: Padding(
              padding: const EdgeInsets.all(4.0),
              child: Text(
                shortcutLabel!,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: Settings.tacticalVioletTheme.mutedForeground,
                    ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

