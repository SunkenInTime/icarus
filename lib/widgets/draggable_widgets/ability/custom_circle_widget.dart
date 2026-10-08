import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_range_fill.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_range_opacity.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class CustomCircleWidget extends ConsumerWidget {
  const CustomCircleWidget({
    super.key,
    required this.iconPath,
    required this.size,
    double? boxSize,
    required this.rangeOutlineColor,
    required this.hasCenterDot,
    this.opacity = 70,
    this.rangeFillColor,
    this.innerRangeColor,
    this.innerRangeSize,
    required this.id,
    required this.isAlly,
    this.landingId,
    this.visualState,
    this.watchMouse = true,
    this.contextMenuItems,
  }) : boxSize = boxSize ?? size;

  final String? landingId;
  final bool isAlly;
  final String? id;
  final String iconPath;
  final double size;

  /// The square the circle is centered in; see [CircleAbility.storedSize].
  final double boxSize;
  final Color rangeOutlineColor;
  final bool hasCenterDot;
  final int? opacity;
  final Color? rangeFillColor;
  final Color? innerRangeColor;
  final double? innerRangeSize;
  final AbilityVisualState? visualState;
  final bool watchMouse;
  final List<ShadContextMenuItem>? contextMenuItems;

  bool get hasInnerRange => innerRangeSize != null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final scaledSize = coordinateSystem.scale(size);
    final scaledInnerRangeSize = coordinateSystem.scale(innerRangeSize ?? 0);
    final resolvedVisualState = visualState ?? const AbilityVisualState();
    final rangeOpacity = AbilityRangeOpacity.of(context);

    final scaledBoxSize = coordinateSystem.scale(boxSize);

    return SizedBox(
      width: scaledBoxSize,
      height: scaledBoxSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          _buildRangeFill(
            scaledSize,
            showRangeFill: resolvedVisualState.showRangeFill && !hasInnerRange,
            rangeOpacity: rangeOpacity,
          ),
          _buildRangeOutline(
            coordinateSystem,
            scaledSize,
            showRangeOutline: resolvedVisualState.showRangeOutline,
            rangeOpacity: rangeOpacity,
          ),
          if (hasInnerRange) ...[
            _buildInnerRangeFill(
              scaledInnerRangeSize,
              showInnerFill: resolvedVisualState.showInnerFill,
              rangeOpacity: rangeOpacity,
            ),
            _buildInnerRangeOutline(
              coordinateSystem,
              scaledInnerRangeSize,
              showInnerOutline: resolvedVisualState.showInnerOutline,
              rangeOpacity: rangeOpacity,
            ),
          ],
          if (hasCenterDot) _buildCenterIcon(),
        ],
      ),
    );
  }

  Widget _buildRangeFill(
    double scaledSize, {
    required bool showRangeFill,
    required double rangeOpacity,
  }) {
    final fillColor = resolveAbilityRangeFillColor(
      rangeOutlineColor: rangeOutlineColor,
      rangeFillColor: rangeFillColor,
      opacity: opacity,
    );
    return Opacity(
      key: const ValueKey('circle-range-fill-layer'),
      opacity: showRangeFill ? rangeOpacity : 0,
      child: IgnorePointer(
        child: Container(
          width: scaledSize,
          height: scaledSize,
          decoration: BoxDecoration(
            color: fillColor,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }

  Widget _buildRangeOutline(
    CoordinateSystem coordinateSystem,
    double scaledSize, {
    required bool showRangeOutline,
    required double rangeOpacity,
  }) {
    return Opacity(
      key: const ValueKey('circle-range-outline-layer'),
      opacity: showRangeOutline ? rangeOpacity : 0,
      child: IgnorePointer(
        child: Container(
          width: scaledSize,
          height: scaledSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: hasInnerRange
                  ? rangeOutlineColor.withAlpha(100)
                  : rangeOutlineColor,
              width:
                  coordinateSystem.scale(hasInnerRange || hasCenterDot ? 2 : 5),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInnerRangeFill(
    double scaledInnerRangeSize, {
    required bool showInnerFill,
    required double rangeOpacity,
  }) {
    return Positioned.fill(
      child: Opacity(
        key: const ValueKey('circle-inner-fill-layer'),
        opacity: showInnerFill ? rangeOpacity : 0,
        child: IgnorePointer(
          child: Align(
            alignment: Alignment.center,
            child: Container(
              width: scaledInnerRangeSize,
              height: scaledInnerRangeSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: innerRangeColor!.withAlpha(opacity ?? 70),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInnerRangeOutline(
    CoordinateSystem coordinateSystem,
    double scaledInnerRangeSize, {
    required bool showInnerOutline,
    required double rangeOpacity,
  }) {
    return Positioned.fill(
      child: Opacity(
        key: const ValueKey('circle-inner-outline-layer'),
        opacity: showInnerOutline ? rangeOpacity : 0,
        child: IgnorePointer(
          child: Align(
            alignment: Alignment.center,
            child: Container(
              width: scaledInnerRangeSize,
              height: scaledInnerRangeSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: innerRangeColor!,
                  width: coordinateSystem.scale(2),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCenterIcon() {
    return Positioned.fill(
      child: Align(
        alignment: Alignment.center,
        child: AbilityWidget(
          landingId: landingId,
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
