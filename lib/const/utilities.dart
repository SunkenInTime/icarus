import 'package:flutter/material.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/image_utility_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';

enum UtilityType {
  spike,
  viewCone180,
  viewCone90,
  viewCone40,
}

class UtilityData {
  final UtilityType type;

  UtilityData({required this.type});

  static Map<UtilityType, Utilities> utilityWidgets = {
    UtilityType.spike: ImageUtility(imagePath: 'assets/spike.svg', size: 20),
    UtilityType.viewCone180: ViewConeUtility(angle: 103, defaultLength: 50),
    UtilityType.viewCone90: ViewConeUtility(angle: 90, defaultLength: 50),
    UtilityType.viewCone40: ViewConeUtility(angle: 40, defaultLength: 50),
  };

  /// Helper to check if a utility type is a view cone
  static bool isViewCone(UtilityType type) {
    return type == UtilityType.viewCone180 ||
        type == UtilityType.viewCone90 ||
        type == UtilityType.viewCone40;
  }

  /// Get the angle for a view cone type
  static double getViewConeAngle(UtilityType type) {
    switch (type) {
      case UtilityType.viewCone180:
        return 180;
      case UtilityType.viewCone90:
        return 90;
      case UtilityType.viewCone40:
        return 40;
      default:
        return 0;
    }
  }
}

abstract class Utilities {
  Offset getAnchorPoint();
  Widget createWidget(String? id, [double? rotation, double? length]);
}

class ImageUtility extends Utilities {
  final String imagePath;
  final double size;

  ImageUtility({required this.imagePath, required this.size});

  @override
  Widget createWidget(String? id, [double? rotation, double? length]) {
    return ImageUtilityWidget(imagePath: imagePath, size: size, id: id);
  }

  @override
  Offset getAnchorPoint() {
    return Offset(size / 2, size / 2);
  }
}

/// Utility class for view cone widgets (180°, 90°, 40° presets)
class ViewConeUtility extends Utilities {
  final double angle;
  final double defaultLength;

  ViewConeUtility({
    required this.angle,
    this.defaultLength = 50,
  });

  @override
  Widget createWidget(String? id, [double? rotation, double? length]) {
    return ViewConeWidget(
      id: id,
      angle: angle,
      rotation: rotation,
      length: length ?? defaultLength,
    );
  }

  /// Get the anchor point at the bottom center (apex of the cone)
  /// The length determines where the bottom center is positioned
  @override
  Offset getAnchorPoint() {
    return const Offset(300, 300 + 7.5 + 5);
  }

  // /// Get anchor point with length - bottom center of the view cone
  // /// Similar to how SquareAbility calculates its anchor
  // Offset getAnchorPointWithLength({
  //   required double length,
  // }) {
  //   // The widget is sized to contain the cone
  //   // Width = 2 * length (cone can extend left and right)
  //   // Height = length (cone extends upward from bottom)
  //   // Anchor point is at the bottom center: (length, length)
  //   final scaledLength = length;
  //   return Offset(scaledLength, scaledLength);
  // }
}
