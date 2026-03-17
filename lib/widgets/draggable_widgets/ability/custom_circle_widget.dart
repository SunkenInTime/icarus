import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_widget.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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
    this.visualState,
    this.watchMouse = true,
    this.contextMenuItems,
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
  final AbilityVisualState? visualState;
  final bool watchMouse;
  final List<ShadContextMenuItem>? contextMenuItems;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final scaleSize = coordinateSystem.scale(size);
    final secondaryScaleSize = coordinateSystem.scale(innerSize ?? 0);
    final resolvedVisualState = visualState ?? const AbilityVisualState();
    final showPerimeter = resolvedVisualState.showPerimeter;
    final showRangeBody = resolvedVisualState.showRangeBody;

    // If no center dot is needed, return a simple circle
    if (!hasCenterDot) {
      return _buildSimpleCircle(
        coordinateSystem,
        scaleSize,
        showPerimeter: showPerimeter,
        showRangeBody: showRangeBody,
      );
    }

    // With center dot, build appropriate stack based on perimeter setting
    return Stack(
      children: [
        // Outer circle/perimeter
        _buildOuterCircle(
          coordinateSystem,
          scaleSize,
          hasPerimeter,
          showPerimeter: showPerimeter,
          showRangeBody: showRangeBody,
        ),

        // Inner circle (only when has perimeter)
        if (hasPerimeter)
          _buildInnerCircle(
            coordinateSystem,
            secondaryScaleSize,
            showRangeBody: showRangeBody,
          ),

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
    CoordinateSystem coordinateSystem,
    double scaleSize, {
    required bool showPerimeter,
    required bool showRangeBody,
  }) {
    return Stack(
      children: [
        Opacity(
          key: const ValueKey('circle-size-layer'),
          opacity: showRangeBody ? 1 : 0,
          child: IgnorePointer(
            child: Container(
              width: scaleSize,
              height: scaleSize,
              decoration: BoxDecoration(
                color: outlineColor.withAlpha(opacity ?? 70),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
        Opacity(
          key: const ValueKey('circle-perimeter-layer'),
          opacity: showPerimeter ? 1 : 0,
          child: IgnorePointer(
            child: Container(
              width: scaleSize,
              height: scaleSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: outlineColor,
                  width: coordinateSystem.scale(5),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOuterCircle(
      CoordinateSystem coordinateSystem, double scaleSize, bool hasPerimeter,
      {required bool showPerimeter, required bool showRangeBody}) {
    if (!hasPerimeter) {
      return Stack(
        children: [
          Opacity(
            key: const ValueKey('circle-size-layer'),
            opacity: showRangeBody ? 1 : 0,
            child: IgnorePointer(
              child: Container(
                width: scaleSize,
                height: scaleSize,
                decoration: BoxDecoration(
                  color: outlineColor.withAlpha(opacity ?? 70),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
          Opacity(
            key: const ValueKey('circle-perimeter-layer'),
            opacity: showPerimeter ? 1 : 0,
            child: IgnorePointer(
              child: Container(
                width: scaleSize,
                height: scaleSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: outlineColor,
                    width: coordinateSystem.scale(2),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Opacity(
      key: const ValueKey('circle-perimeter-layer'),
      opacity: showPerimeter ? 1 : 0,
      child: IgnorePointer(
        child: Container(
          width: scaleSize,
          height: scaleSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: outlineColor.withAlpha(100),
              width: coordinateSystem.scale(2),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInnerCircle(
      CoordinateSystem coordinateSystem, double secondaryScaleSize,
      {required bool showRangeBody}) {
    return Positioned.fill(
      child: Opacity(
        key: const ValueKey('circle-size-layer'),
        opacity: showRangeBody ? 1 : 0,
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
          watchMouse: watchMouse,
          contextMenuItems: contextMenuItems,
        ),
      ),
    );
  }
}
