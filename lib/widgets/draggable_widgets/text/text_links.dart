import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:icarus/const/caption_links.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_markup.dart';
import 'package:url_launcher/url_launcher.dart';

/// One stretch of a text box's line as it is drawn, a link when it has a
/// [uri].
typedef TextPiece = ({String text, bool bold, bool italic, Uri? uri});

/// [line] as the stretches it is drawn in, with the links a caption would
/// find in what the line shows.
///
/// An address can hold underscores, which also mark italic, like the two in
/// `youtu.be/a_b_c`. Read as markup they would vanish, and the address shown
/// would not be the one typed. So a link that has them is drawn as it was
/// typed, and what a link shows is always where it goes. Asterisks aren't
/// part of an address: bold put on half of one stays bold.
List<TextPiece> textPieces(MarkupLine line) {
  final typedText = StringBuffer();
  // For each character the line shows: where it is in the line as typed, and
  // the stretch that styles it.
  final typedAt = <int>[];
  final styleAt = <MarkupInline>[];
  for (final inline in line.inlines) {
    if (!inline.isMarker) {
      for (var i = 0; i < inline.raw.length; i++) {
        typedAt.add(typedText.length + i);
        styleAt.add(inline);
      }
    }
    typedText.write(inline.raw);
  }
  final typed = typedText.toString();
  final shown = line.plainText;

  final pieces = <TextPiece>[];
  void add(int start, int end, Uri? uri) {
    var from = start;
    for (var i = start + 1; i <= end; i++) {
      if (i < end && identical(styleAt[i], styleAt[from])) continue;
      pieces.add((
        text: shown.substring(from, i),
        bold: styleAt[from].bold,
        italic: styleAt[from].italic,
        uri: uri,
      ));
      from = i;
    }
  }

  var at = 0;
  for (final run in captionRuns(shown)) {
    final end = at + run.text.length;
    final asTyped = run.uri == null
        ? run.text
        : typed.substring(typedAt[at], typedAt[end - 1] + 1);
    if (asTyped.replaceAll('*', '') == run.text) {
      add(at, end, run.uri);
    } else if (captionRuns(asTyped) case [(text: _, :final uri?)]
        when !asTyped.contains('*')) {
      pieces.add((
        text: asTyped,
        bold: styleAt[at].bold,
        italic: styleAt[at].italic,
        uri: uri,
      ));
    } else {
      add(at, end, null);
    }
    at = end;
  }
  return pieces;
}

/// The links in a text box's [text], in the order they are written, each
/// once.
List<Uri> textLinks(String text) => {
      for (final line in parseMarkup(text))
        for (final piece in textPieces(line))
          if (piece.uri case final uri?) uri,
    }.toList();

/// A link in a text box. It takes no click of its own, so a press on it
/// drags, selects and edits the box like a press anywhere else on it: whoever
/// handles the click asks [textLinkAt] what is under it.
class TextLinkSpan extends TextSpan {
  const TextLinkSpan({required this.uri, super.text, super.style})
      : super(mouseCursor: SystemMouseCursors.click);

  final Uri uri;
}

/// The link drawn at [position], a point in global coordinates, in the text
/// boxes under [root], or null when the topmost thing there isn't a link.
Uri? textLinkAt(RenderBox root, Offset position) {
  if (!root.attached || !root.hasSize) return null;
  final result = BoxHitTestResult();
  root.hitTest(result, position: root.globalToLocal(position));
  for (final entry in result.path) {
    if (entry.target case TextLinkSpan(:final uri)) return uri;
  }
  return null;
}

/// How the click that opens a link is written, beside Open link in a menu.
String get openLinkShortcut => defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.iOS
    ? '⌘ click'
    : 'Ctrl+click';

/// Opens [uri] in the browser, as a link in a caption opens.
Future<bool> openTextLink(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);
