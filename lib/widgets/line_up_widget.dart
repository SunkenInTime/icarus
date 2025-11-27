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
    final agentSize = ref.watch(strategySettingsProvider).agentSize;
    final abilitySize = ref.watch(strategySettingsProvider).abilitySize;

    final isHovered = ref.watch(hoveredLineUpIdProvider) == lineUp.id;

    // Compute screen positions
    final agentScreen =
        coordinateSystem.coordinateToScreen(lineUp.agent.position);
    final abilityAnchor = lineUp.ability.data.abilityData!
        .getAnchorPoint(mapScale, abilitySize)
        .scale(coordinateSystem.scaleFactor, coordinateSystem.scaleFactor);
    final abilityScreen =
        coordinateSystem.coordinateToScreen(lineUp.ability.position);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Agent (centered at its position)
        Positioned(
          left: agentScreen.dx,
          top: agentScreen.dy,
          child: MouseRegion(
            onEnter: (_) => ref
                .read(hoveredLineUpIdProvider.notifier)
                .setHoveredLineUpId(lineUp.id),
            onExit: (_) {
              // Only clear if this lineup is currently set
              if (ref.read(hoveredLineUpIdProvider) == lineUp.id) {
                ref
                    .read(hoveredLineUpIdProvider.notifier)
                    .setHoveredLineUpId(null);
              }
            },
            child: AgentWidget(
              agent: AgentData.agents[lineUp.agent.type]!,
              isAlly: true,
              id: lineUp.id,
            ),
          ),
        ),

        // Ability (position adjusted by its anchor)
        Positioned(
          left: abilityScreen.dx,
          top: abilityScreen.dy,
          child: MouseRegion(
            onEnter: (_) => ref
                .read(hoveredLineUpIdProvider.notifier)
                .setHoveredLineUpId(lineUp.id),
            onExit: (_) {
              // Only clear if this lineup is currently set
              if (ref.read(hoveredLineUpIdProvider) == lineUp.id) {
                ref
                    .read(hoveredLineUpIdProvider.notifier)
                    .setHoveredLineUpId(null);
              }
            },
            child: Container(
              decoration: isHovered
                  ? BoxDecoration(
                      border:
                          Border.all(color: const Color(0xFFFFFFFF), width: 2),
                      borderRadius: const BorderRadius.all(Radius.circular(3)),
                    )
                  : null,
              child: lineUp.ability.data.abilityData!.createWidget(
                null,
                true,
                mapScale,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
