import 'package:flutter/material.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/image_scale_policy.dart';

abstract final class PlacedImageDimensions {
  static const double tagWidth = 10.0;
  static const double tagGap = 2.0;
  static const double imagePadding = 5.0;

  static Size screenSize({
    required CoordinateSystem coordinateSystem,
    required double scale,
    required double aspectRatio,
  }) {
    final safeAspectRatio = aspectRatio <= 0 ? 1.0 : aspectRatio;
    final totalWidth =
        coordinateSystem.worldWidthToScreen(ImageScalePolicy.clamp(scale));
    final cardWidth =
        (totalWidth - tagWidth - tagGap).clamp(1.0, double.infinity);
    final contentWidth =
        (cardWidth - (imagePadding * 2)).clamp(1.0, double.infinity);
    final totalHeight = (contentWidth / safeAspectRatio) + (imagePadding * 2);

    return Size(totalWidth, totalHeight);
  }
}

abstract final class PlacedTextDimensions {
  static const double tagWidth = 6.0;
  static const double tagGap = 2.0;
  static const double cardHorizontalPadding = 5.0;
  static const double cardVerticalPadding = 6.0;
  static const String emptyTextPlaceholder = 'Write here...';

  static Size screenSize({
    required CoordinateSystem coordinateSystem,
    required double widthWorld,
    required double fontSizeWorld,
    required String text,
  }) {
    final totalWidth = coordinateSystem.worldWidthToScreen(widthWorld);
    final maxContentWidth = contentWidth(
      coordinateSystem: coordinateSystem,
      widthWorld: widthWorld,
    );

    final displayText = text.isEmpty ? ' ' : _withBreakOpportunities(text);
    final style = textStyle(
      coordinateSystem: coordinateSystem,
      fontSizeWorld: fontSizeWorld,
    );

    final painter = TextPainter(
      text: TextSpan(
        text: displayText,
        style: style,
      ),
      maxLines: null,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout(minWidth: maxContentWidth, maxWidth: maxContentWidth);

    final lineMetrics = painter.computeLineMetrics();
    // EditableText can keep one extra wrapped line in its scroll extent.
    final wrappedTextSlack = lineMetrics.length > 1 && lineMetrics.isNotEmpty
        ? lineMetrics.last.height.ceilToDouble()
        : 0.0;
    final totalHeight = painter.height.ceilToDouble() +
        wrappedTextSlack +
        (cardVerticalPadding * 2);
    return Size(totalWidth, totalHeight);
  }

  static double contentWidth({
    required CoordinateSystem coordinateSystem,
    required double widthWorld,
  }) {
    final totalWidth = coordinateSystem.worldWidthToScreen(widthWorld);
    return (totalWidth - tagWidth - tagGap - (cardHorizontalPadding * 2))
        .clamp(1.0, double.infinity);
  }

  static double fontSizePx({
    required CoordinateSystem coordinateSystem,
    required double fontSizeWorld,
  }) {
    return coordinateSystem.worldHeightToScreen(fontSizeWorld);
  }

  static TextStyle textStyle({
    required CoordinateSystem coordinateSystem,
    required double fontSizeWorld,
  }) {
    final fontSizePx = PlacedTextDimensions.fontSizePx(
      coordinateSystem: coordinateSystem,
      fontSizeWorld: fontSizeWorld,
    );
    return TextStyle(fontSize: fontSizePx, height: 1.0);
  }

  static String _withBreakOpportunities(String text) {
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      buffer
        ..writeCharCode(rune)
        ..write('\u200B');
    }
    return buffer.toString();
  }
}
