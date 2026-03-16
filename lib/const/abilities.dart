import 'package:flutter/widgets.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/center_square_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/custom_circle_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/custom_square_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/deadlock_barrier_mesh_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/resizable_square_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/rotatable_image_widget.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_icon_widget.dart';

bool isRotatable(Ability ability) {
  switch (ability) {
    case SquareAbility():
      return true;
    case CenterSquareAbility():
      return true;
    case RotatableImageAbility():
      return true;
    case DeadlockBarrierMeshAbility():
      return true;
    default:
      return false;
  }
}

double _squareRenderedWidth({
  required bool isWall,
  required double width,
  required double mapScale,
  required double abilitySize,
}) {
  return isWall ? abilitySize * 2 : width * mapScale;
}

double _squareRenderedHeight({
  required double height,
  required double distanceBetweenAOE,
  required double mapScale,
}) {
  return (height * mapScale) + (distanceBetweenAOE * mapScale) + 7.5;
}

sealed class Ability {
  //
  Offset getAnchorPoint({double? mapScale, double? abilitySize});
  Offset getSize({double? mapScale, double? abilitySize});
  Widget createWidget({
    String? id,
    required bool isAlly,
    required double mapScale,
    double? rotation,
    double? length,
    List<double>? armLengthsMeters,
    String? lineUpId,
  });
}

class BaseAbility extends Ability {
  final String iconPath;

  BaseAbility({required this.iconPath});

  @override
  Widget createWidget({
    String? id,
    required bool isAlly,
    required double mapScale,
    double? rotation,
    double? length,
    List<double>? armLengthsMeters,
    String? lineUpId,
  }) {
    return AbilityWidget(
      isAlly: isAlly,
      iconPath: iconPath,
      id: id,
      lineUpId: lineUpId,
    );
  }

  @override
  Offset getAnchorPoint({double? mapScale, double? abilitySize}) {
    assert(abilitySize != null, 'abilitySize must be provided');
    // abilitySize is required, so no need for !
    return Offset(abilitySize! / 2, abilitySize / 2);
  }

  @override
  Offset getSize({double? mapScale, double? abilitySize}) {
    assert(abilitySize != null, 'abilitySize must be provided');
    return Offset(abilitySize!, abilitySize);
  }
}

class ImageAbility extends Ability {
  final String imagePath;
  final double size;

  ImageAbility({required this.imagePath, required this.size});

  @override
  Widget createWidget({
    String? id,
    required bool isAlly,
    required double mapScale,
    double? rotation,
    double? length,
    List<double>? armLengthsMeters,
    String? lineUpId,
  }) {
    return AgentIconWidget(
      lineUpId: lineUpId,
      imagePath: imagePath,
      size: size * mapScale,
      id: id,
    );
  }

  @override
  Offset getAnchorPoint({double? mapScale, double? abilitySize}) {
    assert(mapScale != null, 'mapScale must be provided');
    return Offset(size * mapScale! / 2, size * mapScale / 2);
  }

  @override
  Offset getSize({double? mapScale, double? abilitySize}) {
    assert(abilitySize != null, 'abilitySize must be provided');
    assert(mapScale != null, 'mapScale must be provided');
    return Offset(size * mapScale!, size * mapScale);
  }
}

class CircleAbility extends Ability {
  CircleAbility({
    required this.iconPath,
    required size,
    required this.outlineColor,
    this.hasCenterDot,
    this.hasPerimeter,
    this.fillColor,
    this.opacity,
    this.perimeterSize,
  }) : size = size * AgentData.inGameMetersDiameter;

  final double size;
  final Color outlineColor;
  final String iconPath;

  final bool? hasPerimeter;
  final bool? hasCenterDot;
  final Color? fillColor;
  final int? opacity;
  final double? perimeterSize;

  @override
  Offset getAnchorPoint({
    double? mapScale,
    double? abilitySize,
  }) {
    assert(mapScale != null, 'mapScale must be provided');
    return Offset((size * mapScale!) / 2, (size * mapScale) / 2);
  }

  @override
  Offset getSize({double? mapScale, double? abilitySize}) {
    assert(abilitySize != null, 'abilitySize must be provided');
    assert(mapScale != null, 'mapScale must be provided');
    return Offset(size * mapScale!, size * mapScale);
  }

  @override
  Widget createWidget({
    String? id,
    required bool isAlly,
    required double mapScale,
    double? rotation,
    double? length,
    List<double>? armLengthsMeters,
    String? lineUpId,
  }) {
    return CustomCircleWidget(
      iconPath: iconPath,
      size: size * mapScale,
      outlineColor: outlineColor,
      hasCenterDot: hasCenterDot ?? true,
      hasPerimeter: hasPerimeter ?? false,
      opacity: opacity,
      fillColor: fillColor,
      innerSize: perimeterSize != null ? perimeterSize! * mapScale : null,
      id: id,
      isAlly: isAlly,
      lineUpId: lineUpId,
    );
  }
}

class SquareAbility extends Ability {
  final double width;
  final double height;
  final String iconPath;
  final Color color;

  final double distanceBetweenAOE;
  final bool isWall;
  final bool hasTopborder;
  final bool hasSideBorders;
  final bool isTransparent;

  SquareAbility({
    required this.width,
    required this.height,
    required this.iconPath,
    required this.color,
    this.distanceBetweenAOE = 0,
    this.isWall = false,
    this.hasTopborder = false,
    this.hasSideBorders = false,
    this.isTransparent = false,
    double? minHeight,
  });

  @override
  Offset getAnchorPoint({
    double? mapScale,
    double? abilitySize,
  }) {
    assert(mapScale != null, 'mapScale must be provided');
    if (abilitySize == null) {
      abilitySize = Settings.abilitySize;
    }

    return Offset(
      _squareRenderedWidth(
            isWall: isWall,
            width: width,
            mapScale: mapScale!,
            abilitySize: abilitySize,
          ) /
          2,
      _squareRenderedHeight(
        height: height,
        distanceBetweenAOE: distanceBetweenAOE,
        mapScale: mapScale,
      ),
    );
  }

  @override
  Offset getSize({double? mapScale, double? abilitySize}) {
    assert(abilitySize != null, 'abilitySize must be provided');
    assert(mapScale != null, 'mapScale must be provided');

    return Offset(
      _squareRenderedWidth(
        isWall: isWall,
        width: width,
        mapScale: mapScale!,
        abilitySize: abilitySize!,
      ),
      _squareRenderedHeight(
        height: height,
        distanceBetweenAOE: distanceBetweenAOE,
        mapScale: mapScale,
      ),
    );
  }

  @override
  Widget createWidget({
    String? id,
    required bool isAlly,
    required double mapScale,
    double? rotation,
    double? length,
    List<double>? armLengthsMeters,
    String? lineUpId,
  }) {
    return CustomSquareWidget(
      lineUpId: lineUpId,
      color: color,
      width: width * mapScale,
      height: height * mapScale,
      iconPath: iconPath,
      distanceBetweenAOE: distanceBetweenAOE * mapScale,
      rotation: rotation,
      id: id,
      isAlly: isAlly,
      hasTopborder: hasTopborder,
      hasSideBorders: hasSideBorders,
      isWall: isWall,
      isTransparent: isTransparent,
    );
  }
}

class CenterSquareAbility extends Ability {
  final double width;
  final double height;
  final String iconPath;
  final Color color;

  CenterSquareAbility({
    required this.width,
    required this.height,
    required this.iconPath,
    required this.color,
    double? minHeight,
  });

  @override
  Offset getAnchorPoint({double? mapScale, double? abilitySize}) {
    return Offset(
      (abilitySize!) / 2,
      (height * mapScale!) / 2,
    );
  }

  @override
  Offset getSize({double? mapScale, double? abilitySize}) {
    assert(abilitySize != null, 'abilitySize must be provided');
    assert(mapScale != null, 'mapScale must be provided');
    return Offset(abilitySize!, height * mapScale! / 2);
  }

  @override
  Widget createWidget({
    String? id,
    required bool isAlly,
    required double mapScale,
    double? rotation,
    double? length,
    List<double>? armLengthsMeters,
    String? lineUpId,
  }) {
    return CenterSquareWidget(
      color: color,
      width: width * mapScale,
      height: height * mapScale,
      iconPath: iconPath,
      rotation: rotation,
      id: id,
      isAlly: isAlly,
      lineUpId: lineUpId,
    );
  }
}

class RotatableImageAbility extends Ability {
  final String imagePath;
  final double height;
  final double width;

  RotatableImageAbility({
    required this.imagePath,
    required this.height,
    required this.width,
  });

  @override
  Offset getAnchorPoint({double? mapScale, double? abilitySize}) {
    return Offset(width * mapScale! / 2, (height * mapScale / 2) + 30);
  }

  @override
  Offset getSize({double? mapScale, double? abilitySize}) {
    assert(abilitySize != null, 'abilitySize must be provided');
    assert(mapScale != null, 'mapScale must be provided');
    return Offset(width * mapScale!, (height * mapScale / 2) + 30);
  }

  @override
  Widget createWidget({
    String? id,
    required bool isAlly,
    required double mapScale,
    double? rotation,
    double? length,
    List<double>? armLengthsMeters,
    String? lineUpId,
  }) {
    return RotatableImageWidget(
      imagePath: imagePath,
      height: height * mapScale,
      width: width * mapScale,
      id: id,
    );
  }
}

//As much as I would love to extend square
class ResizableSquareAbility extends SquareAbility {
  final double minLength;
  final bool defaultToMaxLength;

  ResizableSquareAbility({
    required super.width,
    required super.height,
    required super.iconPath,
    required super.color,
    super.distanceBetweenAOE,
    super.isWall,
    super.hasTopborder,
    super.hasSideBorders,
    super.isTransparent,
    super.minHeight,
    required this.minLength,
    this.defaultToMaxLength = false,
  });

  double resolveLength(double rawLength) {
    if (rawLength <= 0) {
      return defaultToMaxLength ? height : minLength;
    }

    return rawLength.clamp(minLength, height);
  }

  @override
  Widget createWidget({
    String? id,
    required bool isAlly,
    required double mapScale,
    double? rotation,
    double? length,
    List<double>? armLengthsMeters,
    String? lineUpId,
  }) {
    return ResizableSquareWidget(
      isWall: isWall,
      color: color,
      width: width * mapScale,
      length: resolveLength(length ?? 0) * mapScale,
      maxLength: height * mapScale,
      minLength: minLength * mapScale,
      iconPath: iconPath,
      distanceBetweenAOE: distanceBetweenAOE * mapScale,
      id: id,
      isAlly: isAlly,
      hasTopborder: hasTopborder,
      hasSideBorders: hasSideBorders,
      isTransparent: isTransparent,
      lineUpId: lineUpId,
    );
  }

  Offset getLengthAnchor(double mapScale, double abilitySize) {
    return Offset(
      _squareRenderedWidth(
            isWall: isWall,
            width: width,
            mapScale: mapScale,
            abilitySize: abilitySize,
          ) /
          2,
      (height * mapScale) + 7.5,
    );
  }

  @override
  Offset getAnchorPoint({
    double? mapScale,
    double? abilitySize,
  }) {
    return Offset(
      _squareRenderedWidth(
            isWall: isWall,
            width: width,
            mapScale: mapScale!,
            abilitySize: abilitySize!,
          ) /
          2,
      _squareRenderedHeight(
        height: height,
        distanceBetweenAOE: distanceBetweenAOE,
        mapScale: mapScale,
      ),
    );
  }
}

class DeadlockBarrierMeshAbility extends Ability {
  DeadlockBarrierMeshAbility({
    required this.iconPath,
    required this.color,
  });

  final String iconPath;
  final Color color;

  static const double minArmLengthMeters =
      deadlockBarrierMeshMinArmLengthMeters;
  static const double maxArmLengthMeters =
      deadlockBarrierMeshMaxArmLengthMeters;
  static const List<double> defaultArmLengthsMeters =
      deadlockBarrierMeshDefaultArmLengthsMeters;

  static List<double> normalizeArmLengths(List<double>? armLengthsMeters) {
    return normalizeDeadlockBarrierMeshArmLengths(armLengthsMeters);
  }

  static List<double> reorderArmLengthsForSideSwitch(
      List<double> armLengthsMeters) {
    return reorderDeadlockBarrierMeshArmLengthsForSideSwitch(armLengthsMeters);
  }

  static double maxExtentVirtual({
    required double mapScale,
    required double abilitySize,
  }) {
    // Deadlock side-switch, anchor, and render bounds must all derive from the
    // same outer extent to avoid mirrored placement drift.
    return deadlockBarrierMeshMaxExtent(
      mapScale: mapScale,
      abilitySize: abilitySize,
    );
  }

  @override
  Offset getAnchorPoint({double? mapScale, double? abilitySize}) {
    assert(mapScale != null, 'mapScale must be provided');
    assert(abilitySize != null, 'abilitySize must be provided');
    final extent = maxExtentVirtual(
      mapScale: mapScale!,
      abilitySize: abilitySize!,
    );
    return Offset(extent / 2, extent / 2);
  }

  @override
  Offset getSize({double? mapScale, double? abilitySize}) {
    assert(mapScale != null, 'mapScale must be provided');
    assert(abilitySize != null, 'abilitySize must be provided');
    final extent = maxExtentVirtual(
      mapScale: mapScale!,
      abilitySize: abilitySize!,
    );
    return Offset(extent, extent);
  }

  @override
  Widget createWidget({
    String? id,
    required bool isAlly,
    required double mapScale,
    double? rotation,
    double? length,
    List<double>? armLengthsMeters,
    String? lineUpId,
  }) {
    return DeadlockBarrierMeshWidget(
      lineUpId: lineUpId,
      iconPath: iconPath,
      id: id,
      isAlly: isAlly,
      color: color,
      mapScale: mapScale,
      armLengthsMeters: normalizeArmLengths(armLengthsMeters),
    );
  }
}
