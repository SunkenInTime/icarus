import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';

class LineUpAgentWidget extends ConsumerWidget {
  const LineUpAgentWidget({super.key, required this.lineUp});

  final LineUp lineUp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final agentScreen =
        coordinateSystem.coordinateToScreen(lineUp.agent.position);

    return Positioned(
      key: ValueKey('lineup-agent-${lineUp.id}'),
      left: agentScreen.dx,
      top: agentScreen.dy,
      child: AgentWidget(
        lineUpId: lineUp.id,
        agent: AgentData.agents[lineUp.agent.type]!,
        isAlly: true,
        id: lineUp.id,
      ),
    );
  }
}

class LineUpAbilityWidget extends ConsumerWidget {
  const LineUpAbilityWidget({super.key, required this.lineUp});

  final LineUp lineUp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final mapScale = ref.watch(mapProvider.notifier).mapScale;
    final abilityScreen =
        coordinateSystem.coordinateToScreen(lineUp.ability.position);
    log(lineUp.notes);

    return Positioned(
      key: ValueKey('lineup-ability-${lineUp.id}'),
      left: abilityScreen.dx,
      top: abilityScreen.dy,
      child: lineUp.ability.data.abilityData!.createWidget(
        id: null,
        isAlly: true,
        mapScale: mapScale,
        lineUpId: lineUp.id,
      ),
    );
  }
}
