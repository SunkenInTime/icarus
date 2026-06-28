import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_widget.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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
    this.lineUpItemId,
    this.visualState,
    this.watchMouse = true,
    this.contextMenuItems,
  });
  final double width;
  final double height;
  final String iconPath;
  final Color color;
  final double? rotation;
  final String? id;
  final bool isAlly;
  final String? lineUpId;
  final String? lineUpItemId;
  final AbilityVisualState? visualState;
  final bool watchMouse;
  final List<ShadContextMenuItem>? contextMenuItems;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final abilitySize = ref.watch(strategySettingsProvider).abilitySize;
    final totalWidth = coordinateSystem.scale(abilitySize);
    final scaledWidth = coordinateSystem.scale(width);
    final scaledHeight = coordinateSystem.scale(height);
    final showRangeFill = visualState?.showRangeFill ?? true;
    return SizedBox(
      width: totalWidth,
      height: scaledHeight,
      child: Stack(
        children: [
          Positioned(
            child: Opacity(
              key: const ValueKey('square-range-body'),
              opacity: showRangeFill ? 1 : 0,
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
          ),
          Positioned(
            child: Align(
              alignment: Alignment.center,
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
          ),
        ],
      ),
    );
  }
}
