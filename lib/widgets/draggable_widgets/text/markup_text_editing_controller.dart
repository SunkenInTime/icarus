import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_markup.dart';

class MarkupTextEditingController extends TextEditingController {
  MarkupTextEditingController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final baseStyle = style ?? DefaultTextStyle.of(context).style;
    final mutedStyle = baseStyle.copyWith(
      color: Settings.tacticalVioletTheme.mutedForeground,
    );
    final children = <InlineSpan>[];
    final lines = parseMarkup(text);
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      if (line.prefix.isNotEmpty) {
        children.add(TextSpan(text: line.prefix, style: mutedStyle));
      }
      final headingStyle = line.kind == MarkupLineKind.heading
          ? baseStyle.copyWith(
              fontWeight: FontWeight.w600,
              fontSize: (baseStyle.fontSize ?? 14) * markupHeadingScale,
            )
          : baseStyle;
      for (final inline in line.inlines) {
        final inlineStyle = headingStyle.copyWith(
          color: inline.isMarker
              ? Settings.tacticalVioletTheme.mutedForeground
              : headingStyle.color,
          fontWeight: inline.bold ? FontWeight.w700 : headingStyle.fontWeight,
          fontStyle: inline.italic ? FontStyle.italic : headingStyle.fontStyle,
        );
        children.add(TextSpan(text: inline.raw, style: inlineStyle));
      }
      if (index != lines.length - 1) children.add(const TextSpan(text: '\n'));
    }
    return TextSpan(style: baseStyle, children: children);
  }
}
