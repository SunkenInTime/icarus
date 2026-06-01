import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/canvas_resize_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';

class PlacedLineupAgentWidget extends ConsumerWidget {
  const PlacedLineupAgentWidget({
    super.key,
    required this.agent,
    required this.draggable,
    this.onDragEnd,
  });

  final PlacedAgent agent;
  final bool draggable;
  final void Function(DraggableDetails details)? onDragEnd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(canvasResizeProvider);
    final coordinateSystem = CoordinateSystem.instance;
    final screenPosition = coordinateSystem.coordinateToScreen(agent.position);

    return Positioned(
      left: screenPosition.dx,
      top: screenPosition.dy,
      child: draggable
          ? Draggable<PlacedWidget>(
              data: agent,
              dragAnchorStrategy:
                  ref.read(screenZoomProvider.notifier).zoomDragAnchorStrategy,
              feedback: Opacity(
                opacity: Settings.feedbackOpacity,
                child: ZoomTransform(
                  child: AgentWidget(
                    isAlly: agent.isAlly,
                    id: '',
                    agent: AgentData.agents[agent.type]!,
                  ),
                ),
              ),
              childWhenDragging: const SizedBox.shrink(),
              onDragEnd: onDragEnd,
              child: RepaintBoundary(
                child: AgentWidget(
                  isAlly: agent.isAlly,
                  id: agent.id,
                  agent: AgentData.agents[agent.type]!,
                ),
              ),
            )
          : IgnorePointer(
              ignoring: true,
              child: AgentWidget(
                isAlly: agent.isAlly,
                id: agent.id,
                agent: AgentData.agents[agent.type]!,
              ),
            ),
    );
  }
}
