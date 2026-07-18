import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/const/agents.dart';

class FramedAbilityIconShell extends ConsumerWidget {
  const FramedAbilityIconShell({
    super.key,
    required this.size,
    required this.isAlly,
    required this.child,
    this.lineUpId,
    this.lineUpItemId,
    this.agentType,
    this.scaleFactor = 1.0,
  });

  final double size;
  final bool isAlly;
  final Widget child;
  final String? lineUpId;
  final String? lineUpItemId;
  final AgentType? agentType;
  final double scaleFactor; 

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final hoverTarget = ref.watch(hoveredLineUpTargetProvider);
    final isLineUpHovered = lineUpId != null &&
        lineUpItemId != null &&
        (hoverTarget?.matchesAbility(lineUpId!, lineUpItemId!) ?? false);
    final useNeutralTeamColors =
        ref.watch(strategySettingsProvider).useNeutralTeamColors;

    Color outlineColor = useNeutralTeamColors 
        ? AgentData.agents[agentType]?.color ?? Settings.allyOutlineColor 
        : isAlly ? Settings.allyOutlineColor : Settings.enemyOutlineColor;

    final double baseScaledSize = coordinateSystem.scale(size);

    return Transform.scale(
      scale: scaleFactor,
      alignment: Alignment.center,
      child: Container(
        width: baseScaledSize,
        height: baseScaledSize,
        padding: EdgeInsets.all(coordinateSystem.scale(3)), 
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.all(Radius.circular(3)),
          color: isLineUpHovered ? Colors.deepPurple : Colors.transparent,
        ),
        child: Stack(
          clipBehavior: Clip.none, 
          children: [
            for (double dx in [-1.2, 0.0, 1.2])
            for (double dy in [-1.2, 0.0, 1.2])
            if (dx != 0.0 || dy != 0.0)
            Positioned(
              left: dx,
              top: dy,
              right: -dx,
              bottom: -dy,
              child: ColorFiltered(
                colorFilter: ColorFilter.mode(outlineColor, BlendMode.srcIn),
                child: child, 
              ),
            ),
            child,
          ],
        ),
      ),
    );
  }
}