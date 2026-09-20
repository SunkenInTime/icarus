import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// A shadow cast inward from the edge of a box, like CSS `box-shadow: inset`.
///
/// With [blurRadius] zero this is a crisp inner edge: a 1px [spreadRadius]
/// draws a rim all the way round, a 1px [offset] draws a lit or shaded edge on
/// one side. Flutter's [BoxShadow] cannot do either, so this pairs with
/// [InsetShadowDecoration].
class InsetShadow {
  const InsetShadow({
    required this.color,
    this.offset = Offset.zero,
    this.blurRadius = 0,
    this.spreadRadius = 0,
  });

  final Color color;
  final Offset offset;
  final double blurRadius;
  final double spreadRadius;

  InsetShadow _faded() => InsetShadow(
        color: color.withValues(alpha: 0),
        offset: offset,
        blurRadius: blurRadius,
        spreadRadius: spreadRadius,
      );

  static InsetShadow lerp(InsetShadow a, InsetShadow b, double t) {
    return InsetShadow(
      color: Color.lerp(a.color, b.color, t)!,
      offset: Offset.lerp(a.offset, b.offset, t)!,
      blurRadius: ui.lerpDouble(a.blurRadius, b.blurRadius, t)!,
      spreadRadius: ui.lerpDouble(a.spreadRadius, b.spreadRadius, t)!,
    );
  }

  /// Lerps two lists, fading in or out whatever one side lacks.
  static List<InsetShadow> lerpList(
    List<InsetShadow> a,
    List<InsetShadow> b,
    double t,
  ) {
    final length = a.length > b.length ? a.length : b.length;
    return [
      for (var i = 0; i < length; i++)
        lerp(
          i < a.length ? a[i] : b[i]._faded(),
          i < b.length ? b[i] : a[i]._faded(),
          t,
        ),
    ];
  }
}

/// A rounded box with a fill (flat or [gradient]), optional border, outer
/// [boxShadows], and any number of [InsetShadow]s painted inside its edge.
///
/// Each shadow uses the technique Chromium uses for inset shadows: clip to
/// the box, fill the plane minus a copy of the box that has been moved by the
/// shadow's offset and shrunk by its spread, then blur that ring. The border
/// paints last so it stays crisp over the shadows.
class InsetShadowDecoration extends Decoration {
  const InsetShadowDecoration({
    this.color,
    this.gradient,
    this.borderRadius = BorderRadius.zero,
    this.border,
    this.boxShadows = const [],
    this.shadows = const [],
  });

  final Color? color;

  /// Painted over [color] when set, so a gradient can sit on a base fill.
  final Gradient? gradient;
  final BorderRadius borderRadius;
  final BoxBorder? border;

  /// Ordinary drop shadows, painted outside the box before the fill.
  final List<BoxShadow> boxShadows;
  final List<InsetShadow> shadows;

  @override
  EdgeInsetsGeometry get padding => border?.dimensions ?? EdgeInsets.zero;

  @override
  Path getClipPath(Rect rect, TextDirection textDirection) {
    return Path()..addRRect(borderRadius.toRRect(rect));
  }

  @override
  bool hitTest(Size size, Offset position, {TextDirection? textDirection}) {
    return borderRadius.toRRect(Offset.zero & size).contains(position);
  }

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) {
    return _InsetShadowPainter(this, onChanged);
  }

  // Animated containers can tween to and from this decoration, including
  // from a plain rounded [BoxDecoration], so a selected state can fade in.
  @override
  Decoration? lerpFrom(Decoration? a, double t) {
    final from = _coerce(a);
    return from == null ? null : _lerp(from, this, t);
  }

  @override
  Decoration? lerpTo(Decoration? b, double t) {
    final to = _coerce(b);
    return to == null ? null : _lerp(this, to, t);
  }

  static InsetShadowDecoration? _coerce(Decoration? other) {
    if (other == null) return const InsetShadowDecoration();
    if (other is InsetShadowDecoration) return other;
    if (other is BoxDecoration &&
        other.shape == BoxShape.rectangle &&
        other.image == null &&
        other.backgroundBlendMode == null &&
        (other.borderRadius == null || other.borderRadius is BorderRadius) &&
        (other.border == null || other.border is Border)) {
      return InsetShadowDecoration(
        color: other.color,
        gradient: other.gradient,
        borderRadius:
            (other.borderRadius as BorderRadius?) ?? BorderRadius.zero,
        border: other.border,
        boxShadows: other.boxShadow ?? const [],
      );
    }
    return null;
  }

  static InsetShadowDecoration _lerp(
    InsetShadowDecoration a,
    InsetShadowDecoration b,
    double t,
  ) {
    return InsetShadowDecoration(
      color: Color.lerp(a.color, b.color, t),
      gradient: Gradient.lerp(a.gradient, b.gradient, t),
      borderRadius: BorderRadius.lerp(a.borderRadius, b.borderRadius, t)!,
      border: BoxBorder.lerp(a.border, b.border, t),
      boxShadows: BoxShadow.lerpList(a.boxShadows, b.boxShadows, t) ?? const [],
      shadows: InsetShadow.lerpList(a.shadows, b.shadows, t),
    );
  }
}

class _InsetShadowPainter extends BoxPainter {
  _InsetShadowPainter(this.decoration, super.onChanged);

  final InsetShadowDecoration decoration;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null) {
      return;
    }
    final rect = offset & size;
    final rrect = decoration.borderRadius.toRRect(rect);

    for (final shadow in decoration.boxShadows) {
      canvas.drawRRect(
        rrect.shift(shadow.offset).inflate(shadow.spreadRadius),
        shadow.toPaint(),
      );
    }

    final color = decoration.color;
    if (color != null) {
      canvas.drawRRect(rrect, Paint()..color = color);
    }
    final gradient = decoration.gradient;
    if (gradient != null) {
      canvas.drawRRect(
        rrect,
        Paint()
          ..shader = gradient.createShader(
            rect,
            textDirection: configuration.textDirection,
          ),
      );
    }

    for (final shadow in decoration.shadows) {
      _paintShadow(canvas, rect, rrect, shadow);
    }

    decoration.border?.paint(
      canvas,
      rect,
      textDirection: configuration.textDirection,
      borderRadius: decoration.borderRadius,
    );
  }

  void _paintShadow(Canvas canvas, Rect rect, RRect rrect, InsetShadow shadow) {
    // The hole is the box itself, moved by the offset and shrunk by the
    // spread; whatever it no longer covers inside the clip is the shadow.
    final hole = rrect.shift(shadow.offset).deflate(shadow.spreadRadius);
    // Extend the filled area past the clip so the blur never fades at the
    // box edge, only at the hole edge.
    final reach = shadow.blurRadius + shadow.spreadRadius;
    final outer = rect.inflate(reach + shadow.offset.distance + 1);

    final ring = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(outer)
      ..addRRect(hole);

    final paint = Paint()..color = shadow.color;
    if (shadow.blurRadius > 0) {
      paint.maskFilter = ui.MaskFilter.blur(
        ui.BlurStyle.normal,
        Shadow.convertRadiusToSigma(shadow.blurRadius),
      );
    }

    canvas
      ..save()
      ..clipRRect(rrect)
      ..drawPath(ring, paint)
      ..restore();
  }
}
