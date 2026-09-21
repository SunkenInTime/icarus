import 'package:flutter/material.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_markup.dart';

class FormattedTextView extends StatelessWidget {
  const FormattedTextView({
    super.key,
    required this.text,
    required this.style,
    required this.hintText,
  });

  final String text;
  final TextStyle style;
  final String hintText;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) {
      return Text(
        hintText,
        style: style.copyWith(color: Colors.grey),
      );
    }
    final lines = parseMarkup(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final line in lines) _buildLine(line),
      ],
    );
  }

  Widget _buildLine(MarkupLine line) {
    if (line.plainText.isEmpty) {
      return SizedBox(
        height: (style.fontSize ?? 14) * (style.height ?? 1.2),
      );
    }
    final contentStyle = line.kind == MarkupLineKind.heading
        ? style.copyWith(
            fontWeight: FontWeight.w600,
            fontSize: (style.fontSize ?? 14) * markupHeadingScale,
          )
        : style;
    final content = Text.rich(
      TextSpan(
        style: contentStyle,
        children: [
          for (final inline in line.inlines)
            if (!inline.isMarker)
              TextSpan(
                text: inline.raw,
                style: contentStyle.copyWith(
                  fontWeight:
                      inline.bold ? FontWeight.w700 : contentStyle.fontWeight,
                  fontStyle:
                      inline.italic ? FontStyle.italic : contentStyle.fontStyle,
                ),
              ),
        ],
      ),
    );
    if (line.kind == MarkupLineKind.paragraph ||
        line.kind == MarkupLineKind.heading) {
      return content;
    }
    final glyph =
        line.kind == MarkupLineKind.bullet ? '•' : '${line.number ?? 1}.';
    final glyphWidth = (style.fontSize ?? 14) * 1.6;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: glyphWidth,
          child: Text(
            glyph,
            textAlign: TextAlign.right,
            style: style,
          ),
        ),
        SizedBox(width: (style.fontSize ?? 14) * 0.4),
        Expanded(child: content),
      ],
    );
  }
}
