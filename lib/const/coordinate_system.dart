import 'dart:developer';

import 'package:flutter/material.dart';

class CoordinateSystem {
  // System parameters

  CoordinateSystem._({required Size playAreaSize})
      : _playAreaSize = playAreaSize;

  final Size _playAreaSize;
  Size get playAreaSize => _playAreaSize;

  static const Size screenShotSize = Size(1920, 1080);
  bool isScreenshot = false;

  void setIsScreenshot(bool value) {
    isScreenshot = value;
  }

  static CoordinateSystem? _instance;

  // Use screenshot dimensions when isScreenshot is true; otherwise use play area size
  Size get _effectiveSize => isScreenshot ? screenShotSize : _playAreaSize;

  Size get effectiveSize => _effectiveSize;
  // The normalized coordinate space will maintain this aspect ratio
  final double normalizedHeight = 1000.0;
  final double mapAspectRatio = 1.24;
  final double worldAspectRatio = 16 / 9;

  double get mapNormalizedWidth => normalizedHeight * mapAspectRatio;
  double get worldNormalizedWidth => normalizedHeight * worldAspectRatio;
  double get mapPaddingNormalizedX =>
      (worldNormalizedWidth - mapNormalizedWidth) / 2;

  factory CoordinateSystem({required Size playAreaSize}) {
    _instance = CoordinateSystem._(playAreaSize: playAreaSize);
    return _instance!;
  }

  static CoordinateSystem get instance {
    if (_instance == null) {
      throw StateError(
          "CoordinateSystem must be initialized with playAreaSize first");
    }
    return _instance!;
  }

  Offset screenToCoordinate(Offset screenPoint) {
    final double normalizedX =
        (screenPoint.dx / _effectiveSize.width) * worldNormalizedWidth;
    final double normalizedY =
        (screenPoint.dy / _effectiveSize.height) * normalizedHeight;

    return Offset(normalizedX, normalizedY);
  }

  Offset coordinateToScreen(Offset coordinates) {
    final double screenX =
        (coordinates.dx / worldNormalizedWidth) * (_effectiveSize.width);
    final double screenY =
        (coordinates.dy / normalizedHeight) * (_effectiveSize.height);

    return Offset(screenX, screenY);
  }

  final double _baseHeight = 831.0;
  // Get the scale factor based on screen height
  double get _scaleFactor => _effectiveSize.height / _baseHeight;

  double get scaleFactor => _scaleFactor;
  // Scale any dimension based on height
  double scale(double size) => (size * _scaleFactor);

  double normalize(double value) => (value / _scaleFactor);
  // Scale a size maintaining aspect ratio
  Size scaleSize(Size size) => Size(
        size.width * _scaleFactor,
        size.height * _scaleFactor,
      );

  Offset convertOldCoordinateToNew(Offset oldCoordinate) {
    return oldCoordinate;
  }

  // Convenience method to wrap a widget with scaled dimensions
  Widget scaleWidget({
    required Widget child,
    required Size originalSize,
  }) {
    Size scaledSize = scaleSize(originalSize);
    return SizedBox(
      width: scaledSize.width,
      height: scaledSize.height,
      child: child,
    );
  }

  bool isOutOfBounds(Offset offset) {
    const int tolerance = 10;
    return offset.dx > worldNormalizedWidth - tolerance ||
        offset.dy > normalizedHeight - tolerance ||
        offset.dx < 0 + tolerance ||
        offset.dy < 0 + tolerance;
  }
}
