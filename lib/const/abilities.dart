import 'dart:developer';

import 'package:flutter/widgets.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/center_square_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/custom_circle_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/custom_square_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/resizable_square_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/rotatable_image_widget.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_icon_widget.dart';

abstract class Ability {
  Offset getAnchorPoint([double? mapScale]);
  Widget createWidget(String? id, bool isAlly, double mapScale,
      [double? rotation, double? length]);
}

class BaseAbility extends Ability {
  final String iconPath;

  BaseAbility({required this.iconPath});

  @override
  Widget createWidget(String? id, bool isAlly, double mapScale,
      [double? rotation, double? length]) {
    return AbilityWidget(
      isAlly: isAlly,
      iconPath: iconPath,
      id: id,
    );
  }

  @override
  Offset getAnchorPoint([double? mapScale]) {
    return const Offset(Settings.abilitySize / 2, Settings.abilitySize / 2);
  }
}

class ImageAbility extends Ability {
  final String imagePath;
  final double size;

  ImageAbility({required this.imagePath, required this.size});
  @override
  Widget createWidget(String? id, bool isAlly, double mapScale,
      [double? rotation, double? length]) {
    return AgentIconWidget(imagePath: imagePath, size: size * mapScale);
  }

  @override
  Offset getAnchorPoint([double? mapScale]) {
    return Offset(size / 2, size / 2);
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
  Offset getAnchorPoint([double? mapScale]) {
    return Offset((size * mapScale!) / 2, (size * mapScale) / 2);
  }

  @override
  Widget createWidget(String? id, bool isAlly, double mapScale,
      [double? rotation, double? length]) {
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
  Offset getAnchorPoint([double? mapScale]) {
    return Offset(
      (isWall ? Settings.abilitySize * 2 : width * mapScale!) / 2,
      (height * mapScale!) +
          (distanceBetweenAOE * mapScale) +
          (Settings.abilitySize / 2) +
          7.5,
    );
  }

  @override
  Widget createWidget(String? id, bool isAlly, double mapScale,
      [double? rotation, double? length]) {
    return CustomSquareWidget(
      color: color,
      width: width * mapScale,
      height: height * mapScale,
      iconPath: iconPath,
      distanceBetweenAOE: distanceBetweenAOE * mapScale,
      rotation: rotation,
      origin: getAnchorPoint(mapScale),
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
  Offset getAnchorPoint([double? mapScale]) {
    return Offset(
      (Settings.abilitySize) / 2,
      (height * mapScale!) / 2,
    );
  }

  @override
  Widget createWidget(String? id, bool isAlly, double mapScale,
      [double? rotation, double? length]) {
    return CenterSquareWidget(
      color: color,
      width: width * mapScale,
      height: height * mapScale,
      iconPath: iconPath,
      rotation: rotation,
      origin: getAnchorPoint(mapScale),
      id: id,
      isAlly: isAlly,
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
  Offset getAnchorPoint([double? mapScale]) {
    return Offset(width * mapScale! / 2, (height * mapScale / 2) + 30);
  }

  @override
  Widget createWidget(String? id, bool isAlly, double mapScale,
      [double? rotation, double? length]) {
    return RotatableImageWidget(
      imagePath: imagePath,
      height: height * mapScale,
      width: width * mapScale,
    );
  }
}

//As much as I would love to extend square
class ResizableSquareAbility extends SquareAbility {
  final double minLength;

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
  });

  @override
  Widget createWidget(String? id, bool isAlly, double mapScale,
      [double? rotation, double? length]) {
    return ResizableSquareWidget(
      isWall: isWall,
      color: color,
      width: width * mapScale,
      length: (length ?? 0) * mapScale,
      maxLength: height * mapScale,
      minLength: minLength * mapScale,
      iconPath: iconPath,
      distanceBetweenAOE: distanceBetweenAOE * mapScale,
      origin: getAnchorPoint(mapScale),
      id: id,
      isAlly: isAlly,
      hasTopborder: hasTopborder,
      hasSideBorders: hasSideBorders,
      isTransparent: isTransparent,
    );
  }

  Offset getLengthAnchor(double mapScale) {
    return Offset(
      (isWall ? Settings.abilitySize * 2 : width * mapScale) / 2,
      (height * mapScale) + 7.5,
    );
  }

  @override
  Offset getAnchorPoint([double? mapScale]) {
    return Offset(
      (isWall ? Settings.abilitySize * 2 : width * mapScale!) / 2,
      (height * mapScale!) +
          (distanceBetweenAOE * mapScale) +
          (Settings.abilitySize / 2) +
          7.5,
    );
  }
}
