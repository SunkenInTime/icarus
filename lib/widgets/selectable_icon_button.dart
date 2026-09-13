import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// The secondary icon button's own corner radius (the theme default).
const double _radius = 6;

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

    // A checked tool is a raised command surface. A caller-supplied color
    // (the delete tools' red) stays a flat fill.
    final raised = isSelected && hoverBackgroundColor == null;
    final flatColor =
        isSelected ? hoverBackgroundColor ?? Colors.transparent : null;
    Widget button = ShadIconButton.secondary(
      padding: EdgeInsets.zero,
      icon: icon,
      backgroundColor: flatColor,
      hoverBackgroundColor: flatColor,
      onPressed: onPressed,
    );
    if (raised) {
      button = DecoratedBox(
        decoration: Settings.raisedPrimary(_radius),
        child: button,
      );
    }

    // No tooltip text means no ShadTooltip wrapper; an empty tooltip bubble
    // would still pop up on hover otherwise.
    if (tooltip != null && tooltip!.isNotEmpty) {
      button = ShadTooltip(
        builder: (context) => Text(tooltip!),
        child: button,
      );
    }

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
