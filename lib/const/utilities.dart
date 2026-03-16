import 'package:flutter/material.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/custom_circle_utility_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/custom_rectangle_utility_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/image_utility_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/role_icon_utility_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';

enum UtilityType {
  spike,
  viewCone180,
  viewCone90,
  viewCone40,
  customCircle,
  customRectangle,
  controller,
  duelist,
  initiator,
  sentinel,
}

class UtilityData {
  final UtilityType type;

  UtilityData({required this.type});

  static Map<UtilityType, Utilities> utilityWidgets = {
    UtilityType.spike: ImageUtility(imagePath: 'assets/spike.svg', size: 20),
    UtilityType.viewCone180: ViewConeUtility(angle: 103, defaultLength: 50),
    UtilityType.viewCone90: ViewConeUtility(angle: 60, defaultLength: 50),
    UtilityType.viewCone40: ViewConeUtility(angle: 20, defaultLength: 50),
    UtilityType.customCircle: CustomCircleUtility(),
    UtilityType.customRectangle: CustomRectangleUtility(),
    UtilityType.controller: RoleIconUtility(
      imagePath: 'assets/agents/controller.webp',
    ),
    UtilityType.duelist: RoleIconUtility(
      imagePath: 'assets/agents/duelist.webp',
    ),
    UtilityType.initiator: RoleIconUtility(
      imagePath: 'assets/agents/initiator.webp',
    ),
    UtilityType.sentinel: RoleIconUtility(
      imagePath: 'assets/agents/sentinel.webp',
    ),
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

  static bool isCustomShape(UtilityType type) {
    return type == UtilityType.customCircle ||
        type == UtilityType.customRectangle;
  }

  static bool isRoleIcon(UtilityType type) {
    return type == UtilityType.controller ||
        type == UtilityType.duelist ||
        type == UtilityType.initiator ||
        type == UtilityType.sentinel;
  }

  static bool isAgentAttachable(UtilityType type) {
    return isViewCone(type) || type == UtilityType.customCircle;
  }

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
    return centerPoint.scale(
        scaleFactor * screenZoom, scaleFactor * screenZoom);
  }
}

class CustomShapeToolData implements DraggableData {
  final UtilityType type;
  final Offset centerPoint;
  final double diameterMeters;
  final double widthMeters;
  final double rectLengthMeters;
  final int colorValue;
  final int opacityPercent;

  const CustomShapeToolData({
    required this.type,
    required this.centerPoint,
    required this.diameterMeters,
    required this.widthMeters,
    required this.rectLengthMeters,
    required this.colorValue,
    required this.opacityPercent,
  });

  factory CustomShapeToolData.circle({
    required double diameterMeters,
    required double mapScale,
    required int colorValue,
    required int opacityPercent,
  }) {
    final maxDiameter = CustomCircleUtility.maxDiameterInVirtual(mapScale);
    return CustomShapeToolData(
      type: UtilityType.customCircle,
      centerPoint: Offset(maxDiameter / 2, maxDiameter / 2),
      diameterMeters: diameterMeters,
      widthMeters: 0,
      rectLengthMeters: 0,
      colorValue: colorValue,
      opacityPercent: opacityPercent,
    );
  }

  factory CustomShapeToolData.rectangle({
    required double widthMeters,
    required double rectLengthMeters,
    required double mapScale,
    required int colorValue,
    required int opacityPercent,
  }) {
    final width = widthMeters * AgentData.inGameMetersDiameter * mapScale;
    final rectLength =
        rectLengthMeters * AgentData.inGameMetersDiameter * mapScale;
    return CustomShapeToolData(
      type: UtilityType.customRectangle,
      centerPoint: Offset(rectLength / 2, width / 2),
      diameterMeters: 0,
      widthMeters: widthMeters,
      rectLengthMeters: rectLengthMeters,
      colorValue: colorValue,
      opacityPercent: opacityPercent,
    );
  }

  Offset getScaledCenterPoint({
    required double scaleFactor,
    required double screenZoom,
  }) {
    return centerPoint.scale(
        scaleFactor * screenZoom, scaleFactor * screenZoom);
  }
}

class RoleIconToolData implements DraggableData {
  final UtilityType type;
  final Offset centerPoint;

  const RoleIconToolData({
    required this.type,
    required this.centerPoint,
  });

  factory RoleIconToolData.fromType({
    required UtilityType type,
    required double abilitySize,
  }) {
    return RoleIconToolData(
      type: type,
      centerPoint: UtilityData.utilityWidgets[type]!.getAnchorPoint(
        abilitySize: abilitySize,
      ),
    );
  }

  Offset getScaledCenterPoint({
    required double scaleFactor,
    required double screenZoom,
  }) {
    return centerPoint.scale(
      scaleFactor * screenZoom,
      scaleFactor * screenZoom,
    );
  }
}

class TextToolData implements DraggableData {
  final Offset centerPoint;
  final double width;
  final double height;
  final int? tagColorValue;

  const TextToolData({
    required this.centerPoint,
    required this.width,
    required this.height,
    required this.tagColorValue,
  });

  factory TextToolData.defaults({int? tagColorValue}) {
    const width = 200.0;
    const height = 40.0;
    return TextToolData(
      centerPoint: const Offset(width / 2, height / 2),
      width: width,
      height: height,
      tagColorValue: tagColorValue,
    );
  }

  Offset getScaledCenterPoint({
    required double scaleFactor,
    required double screenZoom,
  }) {
    return centerPoint.scale(
        scaleFactor * screenZoom, scaleFactor * screenZoom);
  }
}

sealed class Utilities {
  Offset getAnchorPoint(
      {String? id,
      double? length,
      double? rotation,
      double? mapScale,
      double? abilitySize,
      double? diameterMeters,
      double? widthMeters,
      double? rectLengthMeters});

  Widget createWidget(
      {String? id,
      bool isAlly = true,
      double? rotation,
      double? length,
      double? mapScale,
      double? abilitySize,
      double? diameterMeters,
      double? widthMeters,
      double? rectLengthMeters,
      bool showCenterMarker = true,
      int? colorValue,
      int? opacityPercent});
  Offset getSize(
      {double? diameterMeters,
      double? widthMeters,
      double? rectLengthMeters,
      double? abilitySize,
      double? mapScale});
}

class ImageUtility extends Utilities {
  final String imagePath;
  final double size;

  ImageUtility({required this.imagePath, required this.size});

  @override
  Widget createWidget(
      {String? id,
      bool isAlly = true,
      double? rotation,
      double? length,
      double? mapScale,
      double? abilitySize,
      double? diameterMeters,
      double? widthMeters,
      double? rectLengthMeters,
      bool showCenterMarker = true,
      int? colorValue,
      int? opacityPercent}) {
    return ImageUtilityWidget(imagePath: imagePath, size: size, id: id);
  }

  @override
  Offset getAnchorPoint(
      {String? id,
      double? length,
      double? rotation,
      double? mapScale,
      double? abilitySize,
      double? diameterMeters,
      double? widthMeters,
      double? rectLengthMeters}) {
    return Offset(size / 2, size / 2);
  }

  @override
  Offset getSize(
      {double? diameterMeters,
      double? widthMeters,
      double? rectLengthMeters,
      double? abilitySize,
      double? mapScale}) {
    return Offset(size, size);
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
  Widget createWidget(
      {String? id,
      bool isAlly = true,
      double? rotation,
      double? length,
      double? mapScale,
      double? abilitySize,
      double? diameterMeters,
      double? widthMeters,
      double? rectLengthMeters,
      bool showCenterMarker = true,
      int? colorValue,
      int? opacityPercent}) {
    return ViewConeWidget(
      id: id,
      angle: angle,
      rotation: rotation,
      length: length ?? defaultLength,
      showCenterMarker: showCenterMarker,
    );
  }

  /// Get the anchor point at the bottom center (apex of the cone)
  /// The length determines where the bottom center is positioned
  @override
  Offset getAnchorPoint(
      {String? id,
      double? length,
      double? rotation,
      double? mapScale,
      double? abilitySize,
      double? diameterMeters,
      double? widthMeters,
      double? rectLengthMeters}) {
    return ViewConeWidget.anchorPointVirtual;
  }

  /// Center point of the eye icon used as canonical placement anchor.
  Offset getCenterPoint() {
    return getAnchorPoint();
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
  Offset getSize(
      {double? diameterMeters,
      double? widthMeters,
      double? rectLengthMeters,
      double? abilitySize,
      double? mapScale}) {
    return Offset(
      ViewConeWidget.totalWidthVirtual,
      ViewConeWidget.totalHeightVirtual,
    );
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

class CustomCircleUtility extends Utilities {
  static const double maxDiameterMeters = 40.0;

  static double diameterInVirtual({
    required double diameterMeters,
    required double mapScale,
  }) {
    return diameterMeters * AgentData.inGameMetersDiameter * mapScale;
  }

  static double maxDiameterInVirtual(double mapScale) {
    return diameterInVirtual(
      diameterMeters: maxDiameterMeters,
      mapScale: mapScale,
    );
  }

  @override
  Widget createWidget(
      {String? id,
      bool isAlly = true,
      double? rotation,
      double? length,
      double? mapScale,
      double? abilitySize,
      double? diameterMeters,
      double? widthMeters,
      double? rectLengthMeters,
      bool showCenterMarker = true,
      int? colorValue,
      int? opacityPercent}) {
    assert(mapScale != null, 'mapScale must be provided');
    assert(diameterMeters != null, 'diameterMeters must be provided');
    assert(colorValue != null, 'colorValue must be provided');
    assert(opacityPercent != null, 'opacityPercent must be provided');
    return CustomCircleUtilityWidget(
      id: id,
      mapScale: mapScale,
      diameterMeters: diameterMeters,
      colorValue: colorValue,
      opacityPercent: opacityPercent,
      showCenterMarker: showCenterMarker,
    );
  }

  @override
  Offset getAnchorPoint(
      {String? id,
      double? length,
      double? rotation,
      double? mapScale,
      double? abilitySize,
      double? diameterMeters,
      double? widthMeters,
      double? rectLengthMeters}) {
    assert(mapScale != null, 'mapScale must be provided');
    final diameter = maxDiameterInVirtual(mapScale!);
    return Offset(diameter / 2, diameter / 2);
  }

  @override
  Offset getSize(
      {double? diameterMeters,
      double? widthMeters,
      double? rectLengthMeters,
      double? abilitySize,
      double? mapScale}) {
    assert(mapScale != null, 'mapScale must be provided');
    final diameter = maxDiameterInVirtual(mapScale!);
    return Offset(diameter, diameter);
  }
}

class CustomRectangleUtility extends Utilities {
  @override
  Widget createWidget(
      {String? id,
      bool isAlly = true,
      double? rotation,
      double? length,
      double? mapScale,
      double? abilitySize,
      double? diameterMeters,
      double? widthMeters,
      double? rectLengthMeters,
      bool showCenterMarker = true,
      int? colorValue,
      int? opacityPercent}) {
    assert(mapScale != null, 'mapScale must be provided');
    assert(widthMeters != null, 'widthMeters must be provided');
    assert(rectLengthMeters != null, 'rectLengthMeters must be provided');
    assert(colorValue != null, 'colorValue must be provided');
    assert(opacityPercent != null, 'opacityPercent must be provided');
    return CustomRectangleUtilityWidget(
      id: id,
      mapScale: mapScale,
      widthMeters: widthMeters,
      rectLengthMeters: rectLengthMeters,
      colorValue: colorValue,
      opacityPercent: opacityPercent,
    );
  }

  @override
  Offset getAnchorPoint(
      {String? id,
      double? length,
      double? rotation,
      double? mapScale,
      double? abilitySize,
      double? diameterMeters,
      double? widthMeters,
      double? rectLengthMeters}) {
    assert(mapScale != null, 'mapScale must be provided');
    assert(widthMeters != null, 'widthMeters must be provided');
    assert(rectLengthMeters != null, 'rectLengthMeters must be provided');
    final width = widthMeters! * AgentData.inGameMetersDiameter * mapScale!;
    final rectLength =
        rectLengthMeters! * AgentData.inGameMetersDiameter * mapScale;
    return Offset(rectLength / 2, width / 2);
  }

  @override
  Offset getSize(
      {double? diameterMeters,
      double? widthMeters,
      double? rectLengthMeters,
      double? abilitySize,
      double? mapScale}) {
    assert(widthMeters != null, 'widthMeters must be provided');
    assert(rectLengthMeters != null, 'rectLengthMeters must be provided');
    assert(mapScale != null, 'mapScale must be provided');
    final width = widthMeters! * AgentData.inGameMetersDiameter * mapScale!;
    final rectLength =
        rectLengthMeters! * AgentData.inGameMetersDiameter * mapScale;
    return Offset(rectLength, width);
  }
}

class RoleIconUtility extends Utilities {
  final String imagePath;

  RoleIconUtility({required this.imagePath});

  @override
  Widget createWidget({
    String? id,
    bool isAlly = true,
    double? rotation,
    double? length,
    double? mapScale,
    double? abilitySize,
    double? diameterMeters,
    double? widthMeters,
    double? rectLengthMeters,
    bool showCenterMarker = true,
    int? colorValue,
    int? opacityPercent,
  }) {
    assert(abilitySize != null, 'abilitySize must be provided');
    return RoleIconUtilityWidget(
      imagePath: imagePath,
      isAlly: isAlly,
      size: abilitySize!,
      id: id,
    );
  }

  @override
  Offset getAnchorPoint({
    String? id,
    double? length,
    double? rotation,
    double? mapScale,
    double? abilitySize,
    double? diameterMeters,
    double? widthMeters,
    double? rectLengthMeters,
  }) {
    assert(abilitySize != null, 'abilitySize must be provided');
    return Offset(abilitySize! / 2, abilitySize / 2);
  }

  @override
  Offset getSize({
    double? diameterMeters,
    double? widthMeters,
    double? rectLengthMeters,
    double? abilitySize,
    double? mapScale,
  }) {
    assert(abilitySize != null, 'abilitySize must be provided');
    return Offset(abilitySize!, abilitySize);
  }
}
