import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_widget.dart';

class CenterSquareWidget extends ConsumerWidget {
  const CenterSquareWidget({
    super.key,
    required this.width,
    required this.height,
    required this.iconPath,
    required this.color,
    this.rotation,
    required this.id,
    required this.isAlly,
    this.lineUpId,
  });
  final double width;
  final double height;
  final String iconPath;
  final Color color;
  final double? rotation;
  final String? id;
  final bool isAlly;
  final String? lineUpId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final abilitySize = ref.watch(strategySettingsProvider).abilitySize;
    final totalWidth = coordinateSystem.scale(abilitySize);
    final scaledWidth = coordinateSystem.scale(width);
    final scaledHeight = coordinateSystem.scale(height);
    return SizedBox(
      width: totalWidth,
      height: scaledHeight,
      child: Stack(
        children: [
          Positioned(
            child: Align(
              alignment: Alignment.center,
              child: IgnorePointer(
                child: Container(
                  width: scaledWidth,
                  height: scaledHeight,
                  decoration: BoxDecoration(
                    color: color.withAlpha(150),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            child: Align(
              alignment: Alignment.center,
              child: AbilityWidget(
                lineUpId: lineUpId,
                iconPath: iconPath,
                id: id,
                isAlly: isAlly,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
