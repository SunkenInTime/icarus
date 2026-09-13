import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/widgets/draggable_widgets/agents/weapon_icon.dart';

class AgentWeaponBadge extends StatelessWidget {
  const AgentWeaponBadge({
    super.key,
    required this.weapon,
    required this.agentSize,
    this.previousWeapon,
    this.transitionProgress = 1,
  });

  final WeaponType weapon;
  final double agentSize;
  final WeaponType? previousWeapon;
  final double transitionProgress;

  @override
  Widget build(BuildContext context) {
    final width = agentSize * Settings.agentWeaponWidthRatio;
    final height = agentSize * Settings.agentWeaponHeightRatio;
    final previous = previousWeapon ?? weapon;
    final progress = transitionProgress.clamp(0.0, 1.0);
    final changing = previous != weapon;

    Widget icon(WeaponType value, double opacity) => Positioned.fill(
          child: Opacity(
            opacity: opacity,
            child: WeaponIcon(
              weapon: value,
              width: width,
              height: height,
              outlineColor: Settings.tacticalVioletTheme.background,
              outlineWidth: agentSize * Settings.agentWeaponOutlineWidthRatio,
            ),
          ),
        );

    return IgnorePointer(
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          children: [
            if (changing && previous != WeaponType.none && progress < 1)
              icon(previous, 1 - progress),
            if (weapon != WeaponType.none && (!changing || progress > 0))
              icon(weapon, changing ? progress : 1),
          ],
        ),
      ),
    );
  }
}
