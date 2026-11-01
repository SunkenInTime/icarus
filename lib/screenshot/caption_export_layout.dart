import 'dart:ui';

/// A caption to print on an exported page, with where its item is drawn.
typedef CaptionExportNote = ({String id, String text, Offset anchor});

/// A printed caption: its number, the numbered dot on its item, and its card.
typedef CaptionExportEntry = ({
  int number,
  String id,
  String text,
  Offset dot,
  Rect card,
});

/// The captions of one exported page. [fits] is false when they can't all be
/// placed: nothing is cut or dropped, so such a page isn't printed with them.
class CaptionExportLayout {
  const CaptionExportLayout({required this.entries, required this.fits});

  static const empty = CaptionExportLayout(entries: [], fits: true);

  final List<CaptionExportEntry> entries;
  final bool fits;
}

/// Sizes of the printed notes, in the 1920 by 1080 export frame.
abstract final class CaptionExportMetrics {
  static const cardGap = 12.0;
  static const framePadding = 24.0;
  static const maxCardWidth = 460.0;
  static const dotRadius = 15.0;
}

/// How long a note takes to read, at about 20 characters a second.
const captionReadCharsPerSecond = 20;

/// Seconds a reader needs for all of [layout].
int captionReadSeconds(CaptionExportLayout layout) {
  final characters = layout.entries.fold(0, (sum, e) => sum + e.text.length);
  return (characters / captionReadCharsPerSecond).ceil();
}

/// How long captions take to fade in and out across a video's transition.
const captionFadeDuration = Duration(milliseconds: 150);

/// How visible the captions of the two pages are [elapsed] into a transition
/// of [total]: the page being left fades out first, then the next fades in as
/// it ends. These run on real time, not the transition's eased curve.
({double from, double to}) captionFades(Duration elapsed, Duration total) {
  final fade = captionFadeDuration.inMicroseconds;
  return (
    from: (1 - elapsed.inMicroseconds / fade).clamp(0.0, 1.0),
    to: ((fade - (total - elapsed).inMicroseconds) / fade).clamp(0.0, 1.0),
  );
}

/// Lays [notes] out in the two margins beside the map.
///
/// A note goes to the margin on its item's side, so the two read together.
/// Numbers run top to bottom down the left margin, then the right. Each column
/// sits near its items' height, and steps past [obstacles], whatever else is
/// drawn in a margin. A column that can't hold its notes sends its last ones
/// to the other margin. When that still can't hold them, the layout doesn't
/// fit.
///
/// [measure] gives a note's card height at a card width, since line breaks and
/// long URLs mean its length says little.
CaptionExportLayout layoutExportCaptions({
  required List<CaptionExportNote> notes,
  required Size frame,
  required double mapLeft,
  required double mapRight,
  required List<Rect> obstacles,
  required double Function(String text, double width) measure,
}) {
  if (notes.isEmpty) return CaptionExportLayout.empty;

  const pad = CaptionExportMetrics.framePadding;
  final leftWidth = (mapLeft - 2 * pad).clamp(
    0.0,
    CaptionExportMetrics.maxCardWidth,
  );
  final rightWidth = (frame.width - mapRight - 2 * pad).clamp(
    0.0,
    CaptionExportMetrics.maxCardWidth,
  );
  final leftX = mapLeft - pad - leftWidth;
  final rightX = mapRight + pad;

  final center = frame.width / 2;
  final left = [for (final n in notes) if (n.anchor.dx < center) n];
  final right = [for (final n in notes) if (n.anchor.dx >= center) n];
  int byHeight(CaptionExportNote a, CaptionExportNote b) =>
      a.anchor.dy.compareTo(b.anchor.dy);
  left.sort(byHeight);
  right.sort(byHeight);

  List<Rect>? place(List<CaptionExportNote> column, double x, double width) {
    if (column.isEmpty) return const [];
    if (width <= 0) return null;
    final inColumn = [
      for (final obstacle in obstacles)
        if (obstacle.overlaps(Rect.fromLTWH(x, 0, width, frame.height)))
          obstacle,
    ]..sort((a, b) => a.top.compareTo(b.top));
    return _fit(
          column,
          x: x,
          width: width,
          bottom: frame.height - pad,
          obstacles: inColumn,
          measure: measure,
          nearItems: true,
        ) ??
        _fit(
          column,
          x: x,
          width: width,
          bottom: frame.height - pad,
          obstacles: inColumn,
          measure: measure,
          nearItems: false,
        );
  }

  // The left column gives up its last notes until it fits, then the right
  // does the same. Whatever the right hands back to a full left column has
  // nowhere else to go, so the page doesn't fit.
  var leftRects = place(left, leftX, leftWidth);
  while (leftRects == null) {
    right
      ..add(left.removeLast())
      ..sort(byHeight);
    leftRects = place(left, leftX, leftWidth);
  }
  var rightRects = place(right, rightX, rightWidth);
  if (rightRects == null) {
    while (rightRects == null) {
      left
        ..add(right.removeLast())
        ..sort(byHeight);
      rightRects = place(right, rightX, rightWidth);
    }
    leftRects = place(left, leftX, leftWidth);
    if (leftRects == null) {
      return const CaptionExportLayout(entries: [], fits: false);
    }
  }

  var number = 0;
  CaptionExportEntry entry(CaptionExportNote note, Rect card) => (
        number: ++number,
        id: note.id,
        text: note.text,
        dot: note.anchor,
        card: card,
      );
  return CaptionExportLayout(
    fits: true,
    entries: [
      for (final (i, note) in left.indexed) entry(note, leftRects[i]),
      for (final (i, note) in right.indexed) entry(note, rightRects[i]),
    ],
  );
}

/// The cards of [column] from the top, or null when they don't all fit. With
/// [nearItems], each starts at its item's height when it can.
List<Rect>? _fit(
  List<CaptionExportNote> column, {
  required double x,
  required double width,
  required double bottom,
  required List<Rect> obstacles,
  required double Function(String text, double width) measure,
  required bool nearItems,
}) {
  const gap = CaptionExportMetrics.cardGap;
  final rects = <Rect>[];
  var top = CaptionExportMetrics.framePadding;
  for (final note in column) {
    final height = measure(note.text, width);
    var y = nearItems ? (note.anchor.dy - height / 2) : top;
    if (y < top) y = top;
    for (final obstacle in obstacles) {
      final card = Rect.fromLTWH(x, y, width, height);
      if (card.overlaps(obstacle.inflate(gap))) y = obstacle.bottom + gap;
    }
    if (y + height > bottom) return null;
    rects.add(Rect.fromLTWH(x, y, width, height));
    top = y + height + gap;
  }
  return rects;
}
