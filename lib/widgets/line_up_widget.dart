import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';

class LineUpWidget extends ConsumerWidget {
  const LineUpWidget({super.key, required this.lineUp});
  final LineUp lineUp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Stack(
      children: [
        //Agent
        Positioned(
          child: AgentWidget(
            agent: AgentData.agents[lineUp.agent.type]!,
            isAlly: true,
            id: lineUp.agent.id,
          ),
        ),

        //Ability
        Positioned(
            child: lineUp.ability.data.abilityData!.createWidget(
          null,
          true,
          ref.watch(mapProvider.notifier).mapScale,
        )),
      ],
    );
  }
}
