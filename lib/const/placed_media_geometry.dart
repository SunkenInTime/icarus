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
    final screenSize = PlacedTextDimensions.sizeForPixelsPerWorldUnit(
      pixelsPerWorldUnit: _referencePixelsPerWorldUnit,
      widthWorld: width,
      fontSizeWorld: textFontSizeInWorld(text),
      text: text.text,
    );
    return screenSize / _referencePixelsPerWorldUnit;
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
