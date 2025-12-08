import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_widget.dart';

class CustomCircleWidget extends ConsumerWidget {
  const CustomCircleWidget({
    super.key,
    required this.iconPath,
    required this.size,
    required this.outlineColor,
    required this.hasCenterDot,
    required this.hasPerimeter,
    this.opacity = 70,
    this.innerSize = 2,
    this.fillColor,
    required this.id,
    required this.isAlly,
    this.lineUpId,
  });

  final String? lineUpId;
  final bool isAlly;
  final String? id;
  final String iconPath;
  final double size;
  final Color outlineColor;
  final bool hasCenterDot;
  final bool hasPerimeter;
  final int? opacity;
  final double? innerSize;
  final Color? fillColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final scaleSize = coordinateSystem.scale(size);
    final secondaryScaleSize = coordinateSystem.scale(innerSize ?? 0);

    // If no center dot is needed, return a simple circle
    if (!hasCenterDot) {
      return _buildSimpleCircle(coordinateSystem, scaleSize);
    }

    // With center dot, build appropriate stack based on perimeter setting
    return Stack(
      children: [
        // Outer circle/perimeter
        _buildOuterCircle(coordinateSystem, scaleSize, hasPerimeter),

        // Inner circle (only when has perimeter)
        if (hasPerimeter)
          _buildInnerCircle(coordinateSystem, secondaryScaleSize),

        // Icon in center
        _buildCenterIcon(coordinateSystem, ref),

        // Container(
        //   width: 4,
        //   height: 4,
        //   color: Colors.red,
        // ),
      ],
    );
  }

  Widget _buildSimpleCircle(
      CoordinateSystem coordinateSystem, double scaleSize) {
    return Container(
      width: scaleSize,
      height: scaleSize,
      decoration: BoxDecoration(
        color: outlineColor.withAlpha(opacity ?? 70),
        shape: BoxShape.circle,
        border: Border.all(
          color: outlineColor,
          width: coordinateSystem.scale(5),
        ),
      ),
    );
  }

  Widget _buildOuterCircle(
      CoordinateSystem coordinateSystem, double scaleSize, bool hasPerimeter) {
    return IgnorePointer(
      child: Container(
        width: scaleSize,
        height: scaleSize,
        decoration: BoxDecoration(
          color: hasPerimeter ? null : outlineColor.withAlpha(opacity ?? 70),
          shape: BoxShape.circle,
          border: Border.all(
            color: hasPerimeter ? outlineColor.withAlpha(100) : outlineColor,
            width: coordinateSystem.scale(2),
          ),
        ),
      ),
    );
  }

  Widget _buildInnerCircle(
      CoordinateSystem coordinateSystem, double secondaryScaleSize) {
    return Positioned.fill(
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.center,
          child: Container(
            width: secondaryScaleSize,
            height: secondaryScaleSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: fillColor!.withAlpha(opacity ?? 70),
              border: Border.all(
                color: fillColor!,
                width: coordinateSystem.scale(2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCenterIcon(CoordinateSystem coordinateSystem, WidgetRef ref) {
    return Positioned.fill(
      child: Align(
        alignment: Alignment.center,
        child: AbilityWidget(
          lineUpId: lineUpId,
          iconPath: iconPath,
          id: id,
          isAlly: isAlly,
        ),
      ),
    );
  }
}
