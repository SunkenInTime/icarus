import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/screenshot/caption_export_layout.dart';
import 'package:icarus/widgets/caption_markers.dart';
import 'package:icarus/widgets/editor_operation_scope.dart';

/// A placed item a page prints the caption of.
typedef CaptionExportItem = ({String id, String text, bool round});

/// A layout measured earlier, drawn over a video frame at [opacity].
typedef FadingCaptions = ({CaptionExportLayout layout, double opacity});

/// The items among those given that hold a caption.
List<CaptionExportItem> captionExportItems(List<PlacedWidget> items) => [
      for (final item in items)
        if (item.caption?.isNotEmpty ?? false)
          (
            id: item.id,
            text: item.caption!,
            round: item is PlacedUtility &&
                item.type == UtilityType.customCircle,
          ),
    ];

const _cardPadding = EdgeInsets.fromLTRB(16, 14, 16, 14);
const _cardEdgeWidth = 2.0;
const _cardRadius = Radius.circular(4);
const _cardDotRadius = 12.0;
const _cardDotGap = 12.0;

TextStyle _noteStyle(BuildContext context) =>
    DefaultTextStyle.of(context).style.merge(
          TextStyle(
            color: Settings.tacticalVioletTheme.foreground,
            decoration: TextDecoration.none,
            fontSize: 20,
            fontWeight: FontWeight.w400,
            height: 1.5,
          ),
        );

double _textWidth(double cardWidth) =>
    cardWidth -
    _cardPadding.horizontal -
    2 * _cardEdgeWidth -
    2 * _cardDotRadius -
    _cardDotGap;

TextPainter _layoutText(String text, TextStyle style, double width) =>
    TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);

double _cardHeight(String text, TextStyle style, double cardWidth) {
  final painter = _layoutText(text, style, _textWidth(cardWidth));
  final height = painter.height;
  painter.dispose();
  return (height > 2 * _cardDotRadius ? height : 2 * _cardDotRadius) +
      _cardPadding.vertical +
      2 * _cardEdgeWidth;
}

void _paintNumber(
  Canvas canvas,
  int number,
  Offset center,
  double radius,
  TextStyle style,
) {
  const colors = Settings.tacticalVioletTheme;
  canvas.drawCircle(center, radius, Paint()..color = colors.foreground);
  canvas.drawCircle(
    center,
    radius,
    Paint()
      ..color = colors.background
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5,
  );
  final label = _layoutText(
    '$number',
    style.copyWith(
      color: colors.background,
      fontSize: radius,
      fontWeight: FontWeight.w700,
      height: 1,
    ),
    radius * 4,
  );
  label.paint(canvas, center - Offset(label.width, label.height) / 2);
  label.dispose();
}

void _paintLayout(
  Canvas canvas,
  Size frame,
  CaptionExportLayout layout,
  TextStyle style,
) {
  const dotRadius = CaptionExportMetrics.dotRadius;
  final inset = Rect.fromLTRB(
    dotRadius,
    dotRadius,
    frame.width - dotRadius,
    frame.height - dotRadius,
  );
  final surface = Paint()..color = Settings.abilityBGColor;
  final edge = Paint()
    ..color = Settings.tacticalVioletTheme.border
    ..style = PaintingStyle.stroke
    ..strokeWidth = _cardEdgeWidth;
  for (final entry in layout.entries) {
    final card = RRect.fromRectAndRadius(entry.card, _cardRadius);
    canvas.drawRRect(card, surface);
    canvas.drawRRect(card.deflate(_cardEdgeWidth / 2), edge);

    final content = entry.card.topLeft +
        Offset(
          _cardEdgeWidth + _cardPadding.left,
          _cardEdgeWidth + _cardPadding.top,
        );
    _paintNumber(
      canvas,
      entry.number,
      content + const Offset(_cardDotRadius, _cardDotRadius),
      _cardDotRadius,
      style,
    );
    final text = _layoutText(entry.text, style, _textWidth(entry.card.width));
    text.paint(
      canvas,
      content + const Offset(2 * _cardDotRadius + _cardDotGap, 0),
    );
    text.dispose();

    _paintNumber(
      canvas,
      entry.number,
      Offset(
        entry.dot.dx.clamp(inset.left, inset.right),
        entry.dot.dy.clamp(inset.top, inset.bottom),
      ),
      dotRadius,
      style,
    );
  }
}

/// A page's captions, printed over the frame: numbered dots on their items and
/// numbered cards in the margins (see [layoutExportCaptions]).
///
/// It measures while it paints, once everything below it is laid out, so what
/// it prints is where the page really drew its items, on either side of the
/// map and at any size. What it worked out goes to [onLayout]. A page whose
/// captions don't fit prints none of them.
class CaptionExportOverlay extends ConsumerWidget {
  const CaptionExportOverlay({
    required this.items,
    required this.drawings,
    required this.isAttack,
    required this.mapLeft,
    required this.mapRight,
    required this.pageName,
    this.onLayout,
    super.key,
  });

  final List<CaptionExportItem> items;
  final List<DrawingElement> drawings;
  final bool isAttack;
  final double mapLeft;
  final double mapRight;

  /// Where the page's name is printed, when it has one.
  final Rect? pageName;
  final ValueChanged<CaptionExportLayout>? onLayout;

  @override
  Widget build(BuildContext context, WidgetRef ref) => CustomPaint(
        size: Size.infinite,
        painter: _PageCaptionsPainter(
          overlay: this,
          registry: ref.read(canvasItemRegistryProvider),
          stack: context.findAncestorRenderObjectOfType<RenderStack>(),
          style: _noteStyle(context),
        ),
      );
}

class _PageCaptionsPainter extends CustomPainter {
  const _PageCaptionsPainter({
    required this.overlay,
    required this.registry,
    required this.stack,
    required this.style,
  });

  final CaptionExportOverlay overlay;
  final CanvasItemRegistry registry;
  final RenderStack? stack;
  final TextStyle style;

  /// The box [element] is drawn in. The page draws defense flipped, around the
  /// middle of the frame.
  Rect? _drawn(DrawingElement element, Size frame) {
    final box = element.boundingBox;
    if (box == null) return null;
    final coordinates = CoordinateSystem.instance;
    final rect = Rect.fromPoints(
      coordinates.coordinateToScreen(box.min),
      coordinates.coordinateToScreen(box.max),
    );
    if (overlay.isAttack) return rect;
    return Rect.fromLTRB(
      frame.width - rect.right,
      frame.height - rect.bottom,
      frame.width - rect.left,
      frame.height - rect.top,
    );
  }

  CaptionExportLayout _measure(Size frame) {
    final stack = this.stack;
    if (stack == null) {
      return const CaptionExportLayout(entries: [], fits: false);
    }
    final outlines = <String, List<Offset>>{};
    final obstacles = <Rect>[
      if (overlay.pageName case final name?) name,
      for (final element in overlay.drawings)
        if (_drawn(element, frame) case final drawn?) drawn,
    ];
    for (final (:item, :corners) in registry.itemsIn(stack)) {
      outlines.putIfAbsent(item.id, () => corners);
      var bounds = Rect.fromPoints(corners.first, corners.first);
      for (final corner in corners) {
        bounds = bounds.expandToInclude(Rect.fromPoints(corner, corner));
      }
      obstacles.add(bounds);
    }

    final notes = <CaptionExportNote>[];
    for (final item in overlay.items) {
      final corners = outlines[item.id];
      // A number with nothing to sit on would print a note for no item.
      if (corners == null) {
        return const CaptionExportLayout(entries: [], fits: false);
      }
      notes.add((
        id: item.id,
        text: item.text,
        anchor: captionMarkerAnchor(corners, round: item.round),
      ));
    }
    return layoutExportCaptions(
      notes: notes,
      frame: frame,
      mapLeft: overlay.mapLeft,
      mapRight: overlay.mapRight,
      obstacles: obstacles,
      measure: (text, width) => _cardHeight(text, style, width),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final layout = _measure(size);
    overlay.onLayout?.call(layout);
    _paintLayout(canvas, size, layout, style);
  }

  // Every capture is of a page that may have just been swapped in.
  @override
  bool shouldRepaint(_PageCaptionsPainter oldDelegate) => true;
}

/// Captions measured from their own pages, over a video's transition frame,
/// which has neither page's items in place to measure.
class FadingCaptionsLayer extends StatelessWidget {
  const FadingCaptionsLayer({required this.captions, super.key});

  final List<FadingCaptions> captions;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.infinite,
        painter: _FadingCaptionsPainter(captions, _noteStyle(context)),
      );
}

class _FadingCaptionsPainter extends CustomPainter {
  const _FadingCaptionsPainter(this.captions, this.style);

  final List<FadingCaptions> captions;
  final TextStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    for (final (:layout, :opacity) in captions) {
      if (opacity <= 0) continue;
      canvas.saveLayer(
        Offset.zero & size,
        Paint()..color = Color.fromRGBO(255, 255, 255, opacity),
      );
      _paintLayout(canvas, size, layout, style);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_FadingCaptionsPainter oldDelegate) => true;
}
