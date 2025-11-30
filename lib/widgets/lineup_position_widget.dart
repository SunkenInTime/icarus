import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';

class LineupPositionWidget extends ConsumerStatefulWidget {
  const LineupPositionWidget({super.key});

  @override
  ConsumerState<LineupPositionWidget> createState() =>
      _LineupPositionWidgetState();
}

class _LineupPositionWidgetState extends ConsumerState<LineupPositionWidget> {
  Offset _pointer = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final placingType = ref.watch(lineUpProvider).placingType;
    final agent = ref.watch(lineUpProvider).currentAgent;
    final ability = ref.watch(lineUpProvider).currentAbility;
    final abilityScale = ref.watch(strategySettingsProvider).abilitySize;
    final normalizedAgentScale = ref.watch(strategySettingsProvider).agentSize *
        CoordinateSystem.instance.scaleFactor;
    final mapScale = ref.watch(mapProvider.notifier).mapScale;

    return MouseRegion(
      cursor: SystemMouseCursors.none,
      onHover: (details) {
        setState(() {
          _pointer = details.localPosition;
        });
      },
      child: GestureDetector(
        onTapUp: (details) {
          if (placingType == PlacingType.agent) {
            ref.read(lineUpProvider.notifier).updatePosition(CoordinateSystem
                .instance
                .screenToCoordinate(details.localPosition -
                    Offset(normalizedAgentScale, normalizedAgentScale)));
          } else if (placingType == PlacingType.ability) {
            ref.read(lineUpProvider.notifier).updatePosition(
                  CoordinateSystem.instance
                          .screenToCoordinate(details.localPosition) -
                      ability!.data.abilityData!.getAnchorPoint(
                          mapScale: mapScale, abilitySize: abilityScale),
                );
          }
        },
        child: Stack(
          children: [
            Container(color: Colors.transparent),
            (placingType == PlacingType.agent)
                ? Positioned(
                    left: _pointer.dx - normalizedAgentScale / 2,
                    top: _pointer.dy - normalizedAgentScale / 2,
                    child: IgnorePointer(
                      child: AgentWidget(
                        agent: AgentData.agents[agent!.type]!,
                        id: "",
                        isAlly: agent.isAlly,
                      ),
                    ),
                  )
                : Positioned(
                    left: _pointer.dx -
                        ability!.data.abilityData!
                            .getAnchorPoint(
                                mapScale: mapScale, abilitySize: abilityScale)
                            .scale(CoordinateSystem.instance.scaleFactor,
                                CoordinateSystem.instance.scaleFactor)
                            .dx,
                    top: _pointer.dy -
                        ability.data.abilityData!
                            .getAnchorPoint(
                                mapScale: mapScale, abilitySize: abilityScale)
                            .scale(CoordinateSystem.instance.scaleFactor,
                                CoordinateSystem.instance.scaleFactor)
                            .dy,
                    child: IgnorePointer(
                        child: ability.data.abilityData!.createWidget(
                            id: "", isAlly: true, mapScale: mapScale)),
                  ),
          ],
        ),
      ),
    );
  }
}
