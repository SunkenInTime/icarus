import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/custom_border_container.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/inactive_ability_trace.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class CustomSquareWidget extends ConsumerWidget {
  const CustomSquareWidget({
    super.key,
    required this.color,
    required this.width,
    required this.height,
    required this.distanceBetweenAOE,
    this.rotation,
    this.lineUpId,
    this.lineUpItemId,
    required this.iconPath,
    required this.id,
    required this.isAlly,
    required this.hasTopborder,
    required this.hasSideBorders,
    required this.isWall,
    required this.isTransparent,
    this.supportsInactiveState = false,
    this.visualState,
    this.watchMouse = true,
    this.contextMenuItems,
  });

  final String? lineUpId;
  final String? lineUpItemId;
  final String? id;
  final Color color;
  final double width;
  final double height;
  final String iconPath;
  final double distanceBetweenAOE;
  final double? rotation;
  final bool isAlly;
  final bool hasTopborder;
  final bool hasSideBorders;
  final bool isWall;
  final bool isTransparent;
  final bool supportsInactiveState;
  final AbilityVisualState? visualState;
  final bool watchMouse;
  final List<ShadContextMenuItem>? contextMenuItems;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;

    final double scaledWidth;
    final abilitySize = ref.watch(strategySettingsProvider).abilitySize;
    if (isWall) {
      scaledWidth = coordinateSystem.scale(abilitySize * 2);
    } else {
      scaledWidth = coordinateSystem.scale(width);
    }
    final resizeButtonOffset = coordinateSystem.scale(7.5);

    final scaledHeight = coordinateSystem.scale(height);
    final scaledDistance = coordinateSystem.scale((distanceBetweenAOE));
    final scaledAbilitySize = coordinateSystem.scale(abilitySize);
    final totalHeight = scaledHeight +
        scaledDistance +
        (scaledAbilitySize / 2) +
        resizeButtonOffset;
    final showRangeFill = visualState?.showRangeFill ?? true;
    final inactiveTraceWidth = coordinateSystem.scale(12);
    final wallBody = IgnorePointer(
      child: Container(
        width: width,
        height: scaledHeight,
        color: color.withAlpha(100),
      ),
    );

    return SizedBox(
      width: scaledWidth,
      height: totalHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Main square

          isWall //This is here because there's a certain size needed to prevent input clipping issues
              ? Positioned(
                  top: 0,
                  left: 0,
                  child: IgnorePointer(
                    child: Container(
                      width: scaledWidth,
                      height: totalHeight,
                      color: Colors.transparent,
                    ),
                  ),
                )
              : Positioned(
                  top: resizeButtonOffset,
                  left: 0,
                  child: Opacity(
                    key: const ValueKey('square-range-body'),
                    opacity: showRangeFill ? 1 : 0,
                    child: IgnorePointer(
                      child: CustomBorderContainer(
                        color: color,
                        width: scaledWidth,
                        height: scaledHeight,
                        hasTop: hasTopborder,
                        hasSide: hasSideBorders,
                        isTransparent: isTransparent,
                      ),
                    ),
                  ),
                ),

          if (isWall)
            Positioned(
              top: resizeButtonOffset,
              left: (scaledWidth / 2) - width / 2,
              child: supportsInactiveState
                  ? AnimatedOpacity(
                      key: const ValueKey('square-range-body-transition'),
                      opacity: showRangeFill ? 1 : 0,
                      duration: abilityStateTransitionDuration,
                      child: wallBody,
                    )
                  : Opacity(
                      key: const ValueKey('square-range-body'),
                      opacity: showRangeFill ? 1 : 0,
                      child: wallBody,
                    ),
            ),
          if (isWall && supportsInactiveState)
            Positioned(
              top: resizeButtonOffset,
              left: (scaledWidth - inactiveTraceWidth) / 2,
              child: AnimatedOpacity(
                key: const ValueKey('inactive-wall-trace-transition'),
                opacity: showRangeFill ? 0 : 1,
                duration: abilityStateTransitionDuration,
                child: IgnorePointer(
                  child: SizedBox(
                    width: inactiveTraceWidth,
                    height: scaledHeight,
                    child: InactiveWallAbilityTrace(color: color),
                  ),
                ),
              ),
            ),
          // Ability icon
          Positioned(
            bottom: 0,
            left: (scaledWidth / 2) - (scaledAbilitySize / 2),
            child: Transform.rotate(
              angle: -(rotation ?? 0),
              alignment: Alignment.center,
              child: AbilityWidget(
                lineUpId: lineUpId,
                lineUpItemId: lineUpItemId,
                iconPath: iconPath,
                id: id,
                isAlly: isAlly,
                watchMouse: watchMouse,
                contextMenuItems: contextMenuItems,
              ),
            ),
          ),
          // Debug point to visualize rotation origin
          // if (false) // Set to true to debug
          //   Positioned(
          //     left: rotationOrigin.dx - 2,
          //     top: rotationOrigin.dy - 2,
          //     child: Container(
          //       width: 4,
          //       height: 4,
          //       color: Colors.red,
          //     ),
          //   ),
        ],
      ),
    );
  }
}
