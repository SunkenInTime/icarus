import 'package:flutter/material.dart';

class CoordinateSystem {
  // System parameters

  CoordinateSystem._({required this.playAreaSize});

  final Size playAreaSize;
  static CoordinateSystem? _instance;

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
        (screenPoint.dx / playAreaSize.width) * normalizedWidth;
    double normalizedY =
        (screenPoint.dy / playAreaSize.height) * normalizedHeight;

    //   dev.log('''
    // Screen to Coordinate:
    // Input Screen Positon: ${screenPoint.dx}, ${screenPoint.dy}
    // PlayAreaSize: ${playAreaSize.width}, ${playAreaSize.height}
    // Output screen pos: $normalizedX, $normalizedY
    // ''');
    return Offset(normalizedX, normalizedY);
  }

  Offset coordinateToScreen(Offset coordinates) {
    // Convert from normalized space back to screen space while maintaining aspect ratio
    double screenX = (coordinates.dx / normalizedWidth) * playAreaSize.width;
    double screenY = (coordinates.dy / normalizedHeight) * playAreaSize.height;

    //   dev.log('''
    // Coordinate to Screen:
    // Input coordinates: ${coordinates.dx}, ${coordinates.dy}
    // PlayAreaSize: ${playAreaSize.width}, ${playAreaSize.height}
    // Output screen pos: $screenX, $screenY
    // ''');
    return Offset(screenX, screenY);
  }

  final double _baseHeight = 831.0;
  // Get the scale factor based on screen height
  double get scaleFactor => playAreaSize.height / _baseHeight;

  // Scale any dimension based on height
  double scale(double size) => size * scaleFactor;

  // Scale a size maintaining aspect ratio
  Size scaleSize(Size size) => Size(
        size.width * scaleFactor,
        size.height * scaleFactor,
      );

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
}
