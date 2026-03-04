import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/custom_border_container.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_widget.dart';

class ResizableSquareWidget extends ConsumerWidget {
  const ResizableSquareWidget({
    super.key,
    required this.color,
    required this.width,
    required this.maxLength,
    required this.minLength,
    required this.iconPath,
    required this.distanceBetweenAOE,
    required this.length,
    this.id,
    required this.isAlly,
    required this.isWall,
    required this.isTransparent,
    required this.hasTopborder,
    required this.hasSideBorders,
    this.lineUpId,
  });

  final Color color;
  final double width;
  final double maxLength;
  final double minLength;
  final String iconPath;
  final double distanceBetweenAOE;
  final double length;
  final String? id;
  final bool isAlly;
  final bool isWall;
  final bool isTransparent;
  final bool hasTopborder;
  final bool hasSideBorders;
  final String? lineUpId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final abilitySize = ref.watch(strategySettingsProvider).abilitySize;
    final double scaledWidth;

    if (isWall) {
      scaledWidth = coordinateSystem.scale(abilitySize * 2);
    } else {
      scaledWidth = coordinateSystem.scale(width);
    }

    final scaledBoxHeight = coordinateSystem.scale(maxLength);

    final scaledDistance = coordinateSystem.scale((distanceBetweenAOE));
    final scaledAbilitySize = coordinateSystem.scale(abilitySize);

    //The 7.5 is to account for the size of the resize button
    final resizeButtonOffset = coordinateSystem.scale(7.5);

    final totalHeight = scaledBoxHeight +
        scaledDistance +
        (scaledAbilitySize / 2) +
        resizeButtonOffset;

    final double scaledLength;
    if (length < minLength) {
      scaledLength = coordinateSystem.scale(minLength);
    } else if (length > maxLength) {
      scaledLength = coordinateSystem.scale(maxLength);
    } else {
      scaledLength = coordinateSystem.scale(length);
    }

    return SizedBox(
      height: totalHeight,
      width: scaledWidth,
      child: Stack(
        children: [
          const Positioned.fill(
            child: IgnorePointer(
              child: SizedBox(),
            ),
          ),
          Positioned(
            bottom: scaledDistance + (scaledAbilitySize / 2),
            left: isWall ? ((scaledWidth - width) / 2) : 0,
            child: IgnorePointer(
              child: CustomBorderContainer(
                height: scaledLength,
                width: isWall ? width : scaledWidth,
                color: color,
                hasTop: hasTopborder,
                hasSide: hasSideBorders,
                isTransparent: isTransparent,
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: (scaledWidth - scaledAbilitySize) / 2,
            child: AbilityWidget(
              lineUpId: lineUpId,
              iconPath: iconPath,
              id: id,
              isAlly: isAlly,
            ),
          ),
        ],
      ),
    );
  }
}
