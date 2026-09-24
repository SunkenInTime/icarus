import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/placed_media_dimensions.dart';

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

    // This describes the pre-Markdown TextField card shipped before canonical
    // coordinates, including its intrinsic vertical chrome and 48 px minimum.
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
    final screenSize = PlacedImageDimensions.sizeForPixelsPerWorldUnit(
      pixelsPerWorldUnit: _referencePixelsPerWorldUnit,
      scale: rawWidth,
      aspectRatio: image.aspectRatio,
    );
    return screenSize / _referencePixelsPerWorldUnit;
  }
}
