import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_links.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_markup.dart';

class FormattedTextView extends StatelessWidget {
  const FormattedTextView({
    super.key,
    required this.text,
    required this.style,
    required this.hintText,
    this.links = true,
  });

  final String text;
  final TextStyle style;
  final String hintText;

  /// Whether addresses in the text are drawn as links. A saved picture or
  /// video draws them as plain text: nothing in a picture can be clicked.
  final bool links;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) {
      return Text(
        hintText,
        style: style.copyWith(color: Colors.grey),
      );
    }
    final fontSize = style.fontSize ?? 14;
    final lines = parseMarkup(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final line in lines) _buildLine(line, fontSize),
      ],
    );
  }

  Widget _buildLine(MarkupLine line, double fontSize) {
    if (line.plainText.isEmpty) {
      return SizedBox(
        height: fontSize * (style.height ?? 1.2),
      );
    }
    final contentStyle = line.kind == MarkupLineKind.heading
        ? style.copyWith(
            fontWeight: FontWeight.w600,
            fontSize: fontSize * markupHeadingScale,
          )
        : style;
    final content = Text.rich(
      TextSpan(
        style: contentStyle,
        children: [
          for (final piece in textPieces(line))
            _span(
              piece,
              contentStyle.copyWith(
                fontWeight:
                    piece.bold ? FontWeight.w700 : contentStyle.fontWeight,
                fontStyle:
                    piece.italic ? FontStyle.italic : contentStyle.fontStyle,
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
    final glyphWidth = fontSize * 1.6;
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
        SizedBox(width: fontSize * 0.4),
        Expanded(child: content),
      ],
    );
  }

  TextSpan _span(TextPiece piece, TextStyle style) {
    final uri = piece.uri;
    if (uri == null || !links) return TextSpan(text: piece.text, style: style);
    return TextLinkSpan(
      uri: uri,
      text: piece.text,
      style: style.copyWith(
        color: Settings.accentInk,
        decoration: TextDecoration.underline,
        decorationColor: Settings.accentInk,
      ),
    );
  }
}
