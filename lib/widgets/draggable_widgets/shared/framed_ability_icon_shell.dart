import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';

class FramedAbilityIconShell extends ConsumerWidget {
  const FramedAbilityIconShell({
    super.key,
    required this.size,
    required this.isAlly,
    required this.child,
    this.lineUpId,
  });

  final double size;
  final bool isAlly;
  final Widget child;
  final String? lineUpId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final isLineUpHovered =
        lineUpId != null && ref.watch(hoveredLineUpIdProvider) == lineUpId;

    return Container(
      width: coordinateSystem.scale(size),
      height: coordinateSystem.scale(size),
      padding: EdgeInsets.all(coordinateSystem.scale(3)),
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(Radius.circular(3)),
        color: isLineUpHovered ? Colors.deepPurple : Settings.abilityBGColor,
        border: Border.all(
          color: isLineUpHovered
              ? Colors.deepPurpleAccent
              : isAlly
                  ? Settings.allyOutlineColor
                  : Settings.enemyOutlineColor,
        ),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(3)),
        child: child,
      ),
    );
  }
}
