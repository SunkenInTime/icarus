import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:icarus/const/image_scale_policy.dart';
import 'package:icarus/const/placed_classes.dart';

abstract final class PlacedMediaGeometry {
  static const double _referencePixelsPerWorldUnit = 1080 / 1000;
  static const double _legacyWidthToWorldFactor = (1000 * (16 / 9)) / 1920;
  static const double _legacyFontToWorldFactor = 1000 / 1080;

  static double textWidthInWorld(PlacedText text) {
    return text.usesWorldSize
        ? text.size
        : text.size * _legacyWidthToWorldFactor;
  }

  static double textFontSizeInWorld(PlacedText text) {
    return text.usesWorldSize
        ? text.fontSize
        : text.fontSize * _legacyFontToWorldFactor;
  }

  static Size legacyTextFootprintInWorld(PlacedText text) {
    final width = textWidthInWorld(text);
    final widthInPixels = width * _referencePixelsPerWorldUnit;
    final fontSizeInPixels =
        textFontSizeInWorld(text) * _referencePixelsPerWorldUnit;

    // The text field sits after the 6 px tag, 2 px gap, and the card's 5 px
    // horizontal padding on each side. Material's borderless field contributes
    // its intrinsic vertical chrome and retains a 48 px minimum height.
    final painter = TextPainter(
      text: TextSpan(
        text: text.text.isEmpty ? 'Write here...' : text.text,
        style: TextStyle(fontSize: fontSizeInPixels),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(0, widthInPixels - 18));
    final heightInPixels = math.max(48, painter.height + 43);

    return Size(width, heightInPixels / _referencePixelsPerWorldUnit);
  }

  static Size legacyImageFootprintInWorld(PlacedImage image) {
    final rawWidth = image.usesWorldSize
        ? image.scale
        : image.scale * _legacyWidthToWorldFactor;
    final width = ImageScalePolicy.clamp(rawWidth);
    final widthInPixels = width * _referencePixelsPerWorldUnit;
    const leftChromeWidth = 12.0;
    final cardWidth = math.max(1, widthInPixels - leftChromeWidth);
    final aspectRatio = image.aspectRatio <= 0 ? 1.0 : image.aspectRatio;
    final heightInPixels = (cardWidth - 10) / aspectRatio + 10;

    return Size(width, heightInPixels / _referencePixelsPerWorldUnit);
  }
}
