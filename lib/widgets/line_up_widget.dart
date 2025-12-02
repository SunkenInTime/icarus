import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_portal/flutter_portal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';

// class LineUpWidget extends ConsumerWidget {
//   LineUpWidget({super.key, required this.lineUp});
//   final LineUp lineUp;
//   final LayerLink _layerLink = LayerLink();
//   final _controller = OverlayPortalController();
//   @override
//   Widget build(BuildContext context, WidgetRef ref) {}
// }

class LineUpWidget extends ConsumerStatefulWidget {
  const LineUpWidget({super.key, required this.lineUp});
  final LineUp lineUp;

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _LineUpWidgetState();
}

class _LineUpWidgetState extends ConsumerState<LineUpWidget> {
  bool isHovering = false;
  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;
    final mapScale = ref.watch(mapProvider.notifier).mapScale;

    // Compute screen positions
    final agentScreen =
        coordinateSystem.coordinateToScreen(widget.lineUp.agent.position);

    final abilityScreen =
        coordinateSystem.coordinateToScreen(widget.lineUp.ability.position);
    log(widget.lineUp.notes);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Agent (centered at its position)
        Positioned(
          left: agentScreen.dx,
          top: agentScreen.dy,
          child: PortalTarget(
            anchor: const Aligned(
              follower: Alignment.bottomCenter,
              target: Alignment.topCenter,
            ),
            visible: isHovering,
            portalFollower: Padding(
              padding: const EdgeInsets.only(bottom: 4.0),
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: Container(
                    padding: const EdgeInsets.all(8.0),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      widget.lineUp.notes,
                      style: const TextStyle(color: Colors.white),
                    ),
                  )),
            ),
            child: MouseRegion(
              onEnter: (event) {
                setState(() {
                  isHovering = true;
                });

                log("Showing overlay for lineup ${widget.lineUp.id}");
              },
              onExit: (event) {
                setState(() {
                  isHovering = false;
                });
                log("Hiding overlay for lineup ${widget.lineUp.id}");
              },
              child: AgentWidget(
                lineUpId: widget.lineUp.id,
                agent: AgentData.agents[widget.lineUp.agent.type]!,
                isAlly: true,
                id: widget.lineUp.id,
              ),
            ),
          ),
        ),

        // Ability (position adjusted by its anchor)
        Positioned(
          left: abilityScreen.dx,
          top: abilityScreen.dy,
          child: widget.lineUp.ability.data.abilityData!.createWidget(
            id: null,
            isAlly: true,
            mapScale: mapScale,
            lineUpId: widget.lineUp.id,
          ),
        ),
      ],
    );
  }
}
