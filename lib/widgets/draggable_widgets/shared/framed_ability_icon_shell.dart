import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

class FramedAbilityIconShell extends ConsumerWidget {
  const FramedAbilityIconShell({
    super.key,
    required this.size,
    required this.isAlly,
    required this.child,
    this.lineUpId,
    this.lineUpItemId,
  });

  final double size;
  final bool isAlly;
  final Widget child;
  final String? lineUpId;
  final String? lineUpItemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final hoverTarget = ref.watch(hoveredLineUpTargetProvider);
    final isLineUpHovered = lineUpId != null &&
        lineUpItemId != null &&
        (hoverTarget?.matchesAbility(lineUpId!, lineUpItemId!) ?? false);
    final useNeutralTeamColors =
        ref.watch(strategySettingsProvider).useNeutralTeamColors;
    final outlineColor =
        isAlly ? Settings.allyOutlineColor : Settings.enemyOutlineColor;

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
              : useNeutralTeamColors
                  ? Settings.neutralTeamShade(outlineColor)
                  : outlineColor,
        ),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(3)),
        child: child,
      ),
    );
  }
}
