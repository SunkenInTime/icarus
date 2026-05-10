import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/team_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class AgentFeedback extends ConsumerWidget {
  const AgentFeedback({
    super.key,
    required this.agent,
  });
  final AgentData agent;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final strategySettings = ref.watch(strategySettingsProvider);
    final agentSize = strategySettings.agentSize;
    final bool isAlly = ref.watch(teamProvider);
    final backgroundColor =
        isAlly ? Settings.allyBGColor : Settings.enemyBGColor;
    final outlineColor =
        isAlly ? Settings.allyOutlineColor : Settings.enemyOutlineColor;
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(3.0)),
      child: Container(
        decoration: BoxDecoration(
          color: strategySettings.useNeutralTeamColors
              ? ShadTheme.of(context).colorScheme.secondary
              : backgroundColor,
          border: Border.all(
            color: strategySettings.useNeutralTeamColors
                ? Settings.neutralTeamShade(outlineColor)
                : outlineColor,
          ),
          borderRadius: const BorderRadius.all(
            Radius.circular(3),
          ),
        ),
        width: coordinateSystem.scale(agentSize),
        child: Image.asset(agent.iconPath),
      ),
    );
  }
}
