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
  });

  final bool isSelected;
  final Widget icon;
  final VoidCallback onPressed;
  final String? tooltip;
  final Color? hoverBackgroundColor;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ShadTooltip(
      builder: (context) => Text(tooltip ?? ''),
      child: ShadIconButton.secondary(
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
  }
}
