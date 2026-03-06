import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/team_provider.dart';

class AgentFeedback extends ConsumerWidget {
  const AgentFeedback({
    super.key,
    required this.agent,
  });
  final AgentData agent;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final agentSize = ref.watch(strategySettingsProvider).agentSize;
    final bool isAlly = ref.watch(teamProvider);
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(3.0)),
      child: Container(
        decoration: BoxDecoration(
          color: isAlly ? Settings.allyBGColor : Settings.enemyBGColor,
          border: Border.all(
            color:
                isAlly ? Settings.allyOutlineColor : Settings.enemyOutlineColor,
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

