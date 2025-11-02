import 'dart:developer';

import 'package:flutter/material.dart';

class CoordinateSystem {
  // System parameters

  CoordinateSystem._({required Size playAreaSize})
      : _playAreaSize = playAreaSize;

  final Size _playAreaSize;
  Size get playAreaSize => _playAreaSize;

  static const Size screenShotSize = Size(1296, 1080);
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
  late final double normalizedWidth = normalizedHeight * 1.24;

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
    // Convert screen points to the normalized space while maintaining aspect ratio
    double normalizedX =
        (screenPoint.dx / _effectiveSize.width) * normalizedWidth;
    double normalizedY =
        (screenPoint.dy / _effectiveSize.height) * normalizedHeight;

    return Offset(normalizedX, normalizedY);
  }

  Offset coordinateToScreen(Offset coordinates) {
    // Convert from normalized space back to screen space while maintaining aspect ratio
    double screenX =
        (coordinates.dx / normalizedWidth) * (_effectiveSize.width);
    double screenY =
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
    // Calculate the ratio between old and new play area heights
    double screenHeight = _effectiveSize.height + 90;
    log("currentScreen height: $screenHeight");
    double oldPlayAreaHeight = screenHeight - 56;
    double newPlayAreaHeight = screenHeight - 90;
    double heightRatio = oldPlayAreaHeight / newPlayAreaHeight;

    log("$heightRatio");
    // Apply the ratio to both dimensions (since width is based on height * 1.2)
    return Offset(
        oldCoordinate.dx * heightRatio, oldCoordinate.dy * heightRatio);
  }

  Offset loggedCoordinateToScreen(Offset coordinates) {
    // Convert from normalized space back to screen space while maintaining aspect ratio
    double screenX =
        (coordinates.dx / normalizedWidth) * (_effectiveSize.width);
    double screenY =
        (coordinates.dy / normalizedHeight) * (_effectiveSize.height);

    log("normalized Coordinates: ${coordinates.toString()}");
    log("screen Coordinates: ${Offset(screenX, screenY).toString()}");

    return Offset(screenX, screenY);
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
    return offset.dx > normalizedWidth - tolerance ||
        offset.dy > normalizedHeight - tolerance ||
        offset.dx < 0 + tolerance ||
        offset.dy < 0 + tolerance;
  }
}
