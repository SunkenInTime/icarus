import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/ability_bar_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_feedback_widget.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';

final dragNotifier = NotifierProvider<DragNotifier, bool>(DragNotifier.new);

class DragNotifier extends Notifier<bool> {
  @override
  bool build() {
    return false;
  }

  void updateDragState(bool isDragging) {
    state = isDragging;
  }
}

class AgentDragable extends ConsumerWidget {
  const AgentDragable({
    super.key,
    required this.agent,
  });
  final AgentData agent;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agentSize = ref.watch(strategySettingsProvider).agentSize;
    return IgnorePointer(
      ignoring: ref.watch(dragNotifier) == true,
      child: Draggable(
        data: agent,
        onDragStarted: () {
          ref.read(dragNotifier.notifier).updateDragState(true);
        },
        onDraggableCanceled: (velocity, offset) {
          ref.read(dragNotifier.notifier).updateDragState(false);
        },
        onDragCompleted: () {
          ref.read(dragNotifier.notifier).updateDragState(false);
        },
        feedback: Opacity(
          opacity: Settings.feedbackOpacity,
          child: ZoomTransform(child: AgentFeedback(agent: agent)),
        ),
        dragAnchorStrategy: (draggable, context, position) => Offset(
          (agentSize / 2),
          (agentSize / 2),
        ).scale(ref.read(screenZoomProvider), ref.read(screenZoomProvider)),
        child: InkWell(
          onTap: () {
            ref.read(abilityBarProvider.notifier).updateData(agent);
          },
          onHover: (value) {},
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: ColoredBox(
              color: (ref.watch(abilityBarProvider) != null &&
                      ref.watch(abilityBarProvider)!.type == agent.type)
                  ? Settings.tacticalVioletTheme.primary
                  : Settings.tacticalVioletTheme.secondary,
              child: Image.asset(
                agent.iconPath,
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
