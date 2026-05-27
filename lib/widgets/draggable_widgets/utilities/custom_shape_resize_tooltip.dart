import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class CustomShapeResizeTooltip extends StatelessWidget {
  const CustomShapeResizeTooltip({
    super.key,
    required this.label,
    required this.valueMeters,
  });

  final String label;
  final double valueMeters;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;

    return IgnorePointer(
      child: Material(
        color: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: scheme.popover,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: scheme.border),
                boxShadow: const [Settings.cardForegroundBackdrop],
              ),
              child: Text(
                '$label ${valueMeters.toStringAsFixed(1)} m',
                style: theme.textTheme.small.copyWith(
                  color: scheme.popoverForeground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Transform.translate(
              offset: const Offset(0, -4),
              child: Transform.rotate(
                angle: math.pi / 4,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: scheme.popover,
                    border: Border.all(color: scheme.border),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
