import 'package:flutter/material.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/custom_shape_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/image_utility_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';

enum UtilityType {
  spike,
  viewCone180,
  viewCone90,
  viewCone40,
  customCircle,
  customRectangle,
}

class UtilityData {
  final UtilityType type;

  UtilityData({required this.type});

  static Map<UtilityType, Utilities> utilityWidgets = {
    UtilityType.spike: ImageUtility(imagePath: 'assets/spike.svg', size: 20),
    UtilityType.viewCone180: ViewConeUtility(angle: 103, defaultLength: 50),
    UtilityType.viewCone90: ViewConeUtility(angle: 60, defaultLength: 50),
    UtilityType.viewCone40: ViewConeUtility(angle: 20, defaultLength: 50),
    UtilityType.customCircle: CustomShapeUtility(
      shape: CustomShapeType.circle,
      widthMeters: 5,
      heightMeters: 5,
    ),
    UtilityType.customRectangle: CustomShapeUtility(
      shape: CustomShapeType.rectangle,
      widthMeters: 5,
      heightMeters: 10,
    ),
  };

  /// Helper to check if a utility type is a view cone
  static bool isViewCone(UtilityType type) {
    return type == UtilityType.viewCone180 ||
        type == UtilityType.viewCone90 ||
        type == UtilityType.viewCone40;
  }

  static bool isCustomShape(UtilityType type) {
    return type == UtilityType.customCircle ||
        type == UtilityType.customRectangle;
  }

  /// Get the angle for a view cone type
  static double getViewConeAngle(UtilityType type) {
    switch (type) {
      case UtilityType.viewCone180:
        return 103;
      case UtilityType.viewCone90:
        return 60;
      case UtilityType.viewCone40:
        return 20;
      default:
        return 0;
    }
  }

  static bool isViewConePresetType(UtilityType type) => isViewCone(type);

  static ViewConeUtility getViewConePreset(UtilityType type) {
    return utilityWidgets[type]! as ViewConeUtility;
  }

  static double getViewConeSpawnAngle(UtilityType type) {
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

class VisionConeToolData implements DraggableData {
  final UtilityType type;
  final double angle;
  final Offset centerPoint;

  const VisionConeToolData({
    required this.type,
    required this.angle,
    required this.centerPoint,
  });

  factory VisionConeToolData.fromType(UtilityType type) {
    final utility = UtilityData.getViewConePreset(type);
    return VisionConeToolData(
      type: type,
      angle: UtilityData.getViewConeSpawnAngle(type),
      centerPoint: utility.getCenterPoint(),
    );
  }
}

class SpikeToolData implements DraggableData {
  final UtilityType type;
  final Offset centerPoint;

  const SpikeToolData({
    required this.type,
    required this.centerPoint,
  });

  factory SpikeToolData.fromUtility(ImageUtility utility) {
    return SpikeToolData(
      type: UtilityType.spike,
      centerPoint: utility.getAnchorPoint(),
    );
  }

  Offset getScaledCenterPoint({
    required double scaleFactor,
    required double screenZoom,
  }) {
    return centerPoint.scale(scaleFactor * screenZoom, scaleFactor * screenZoom);
  }
}

sealed class Utilities {
  Offset getAnchorPoint({String? id, double? length, double? rotation});

  Widget createWidget({String? id, double? rotation, double? length});
  Offset getSize();
}

class ImageUtility extends Utilities {
  final String imagePath;
  final double size;

  ImageUtility({required this.imagePath, required this.size});

  @override
  Widget createWidget({String? id, double? rotation, double? length}) {
    return ImageUtilityWidget(imagePath: imagePath, size: size, id: id);
  }

  @override
  Offset getAnchorPoint({String? id, double? length, double? rotation}) {
    return Offset(size / 2, size / 2);
  }

  @override
  Offset getSize() {
    return Offset(size, size);
  }
}

enum CustomShapeType { circle, rectangle }

class CustomAbilityToolData implements DraggableData {
  final UtilityType type;
  final CustomShapeType shape;
  final double widthMeters;
  final double heightMeters;
  final Color color;

  const CustomAbilityToolData({
    required this.type,
    required this.shape,
    required this.widthMeters,
    required this.heightMeters,
    required this.color,
  });

  Offset getScaledCenterPoint({
    required double scaleFactor,
    required double screenZoom,
  }) {
    final sizeInUnits = widthMeters * AgentData.inGameMetersDiameter;
    final center = Offset(sizeInUnits / 2, sizeInUnits / 2);
    return center.scale(scaleFactor * screenZoom, scaleFactor * screenZoom);
  }
}

class CustomShapeUtility extends Utilities {
  final CustomShapeType shape;
  final double widthMeters;
  final double heightMeters;

  CustomShapeUtility({
    required this.shape,
    required this.widthMeters,
    required this.heightMeters,
  });

  double get widthUnits => widthMeters * AgentData.inGameMetersDiameter;
  double get heightUnits => heightMeters * AgentData.inGameMetersDiameter;

  @override
  Offset getAnchorPoint({String? id, double? length, double? rotation}) {
    return Offset(widthUnits / 2, heightUnits / 2);
  }

  @override
  Offset getSize() {
    return Offset(widthUnits, heightUnits);
  }

  @override
  Widget createWidget({String? id, double? rotation, double? length}) {
    return CustomShapeWidget(
      shape: shape,
      widthMeters: widthMeters,
      heightMeters: heightMeters,
      id: id,
    );
  }

  Widget createWidgetWithParams({
    String? id,
    double? overrideWidthMeters,
    double? overrideHeightMeters,
    Color color = Colors.white,
  }) {
    return CustomShapeWidget(
      shape: shape,
      widthMeters: overrideWidthMeters ?? widthMeters,
      heightMeters: overrideHeightMeters ?? heightMeters,
      id: id,
      color: color,
    );
  }
}

/// Utility class for view cone widgets (180°, 90°, 40° presets)
class ViewConeUtility extends Utilities {
  final double angle;
  final double defaultLength;

  static const double maxLength = 300;
  static const double minLength = 40;
  static const double iconTopOffset = 7.5;

  ViewConeUtility({
    required this.angle,
    this.defaultLength = 50,
  });

  @override
  Widget createWidget({String? id, double? rotation, double? length}) {
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
  Offset getAnchorPoint({String? id, double? length, double? rotation}) {
    return const Offset(maxLength, maxLength + iconTopOffset);
  }

  /// Center point of the eye icon used as canonical placement anchor.
  Offset getCenterPoint() {
    return const Offset(maxLength, maxLength + iconTopOffset);
  }

  /// Returns the drag anchor point in physical pixels.
  Offset getScaledCenterPoint({
    required double scaleFactor,
    required double screenZoom,
  }) {
    final center = getCenterPoint();
    return center.scale(scaleFactor * screenZoom, scaleFactor * screenZoom);
  }

  @override
  Offset getSize() {
    return const Offset(maxLength * 2, maxLength + iconTopOffset);
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
