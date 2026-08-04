import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class CustomShapeResizeTooltip extends StatelessWidget {
  const CustomShapeResizeTooltip({
    super.key,
    required this.label,
    this.valueMeters,
    this.valueDegrees,
    this.valueText,
  }) : assert(
          (valueMeters != null ? 1 : 0) +
                  (valueDegrees != null ? 1 : 0) +
                  (valueText != null ? 1 : 0) ==
              1,
          'Provide exactly one value.',
        );

  final String label;
  final double? valueMeters;
  final double? valueDegrees;
  final String? valueText;

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
                valueText != null
                    ? '$label $valueText'
                    : valueMeters != null
                        ? '$label ${valueMeters!.toStringAsFixed(1)} m'
                        : '$label ${valueDegrees!.toStringAsFixed(0)}°',
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
