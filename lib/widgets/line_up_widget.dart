import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';

class LineUpWidget extends ConsumerWidget {
  const LineUpWidget({super.key, required this.lineUp});
  final LineUp lineUp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final mapScale = ref.watch(mapProvider.notifier).mapScale;

    // Compute screen positions
    final agentScreen =
        coordinateSystem.coordinateToScreen(lineUp.agent.position);

    final abilityScreen =
        coordinateSystem.coordinateToScreen(lineUp.ability.position);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Agent (centered at its position)
        Positioned(
          left: agentScreen.dx,
          top: agentScreen.dy,
          child: AgentWidget(
            lineUpId: lineUp.id,
            agent: AgentData.agents[lineUp.agent.type]!,
            isAlly: true,
            id: lineUp.id,
          ),
        ),

        // Ability (position adjusted by its anchor)
        Positioned(
          left: abilityScreen.dx,
          top: abilityScreen.dy,
          child: lineUp.ability.data.abilityData!.createWidget(
            id: null,
            isAlly: true,
            mapScale: mapScale,
            lineUpId: lineUp.id,
          ),
        ),
      ],
    );
  }
}
