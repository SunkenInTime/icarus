import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Single-line text that truncates with an ellipsis and reveals the full
/// value in a tooltip on hover — but only when it actually overflows.
class OverflowTooltipText extends StatelessWidget {
  const OverflowTooltipText(
    this.text, {
    super.key,
    this.style,
    this.textAlign,
  });

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final theme = ShadTheme.of(context);
        final scheme = theme.colorScheme;
        final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);

        final painter = TextPainter(
          text: TextSpan(text: text, style: effectiveStyle),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.didExceedMaxLines;
        painter.dispose();

        final child = Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: textAlign,
          style: style,
        );
        if (!overflows) return child;

        return Tooltip(
          message: text,
          waitDuration: const Duration(milliseconds: 400),
          decoration: BoxDecoration(
            color: scheme.popover,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: scheme.border),
            boxShadow: const [Settings.cardForegroundBackdrop],
          ),
          textStyle: theme.textTheme.small.copyWith(
            color: scheme.popoverForeground,
            fontWeight: FontWeight.w600,
          ),
          child: child,
        );
      },
    );
  }
}
