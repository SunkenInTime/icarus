import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/widgets/dialogs/create_lineup_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

String lineUpPlacementStatus(LineUpPlacement placement) {
  switch (placement.mode) {
    case LineUpPlacementMode.fresh:
      return placement.hasOrigin
          ? 'Drag an ability to where it lands'
          : 'Drag an agent to where you throw from';
    case LineUpPlacementMode.fromPinnedOrigin:
      return placement.hasLanding
          ? 'Origin pinned · Ability placed'
          : 'Origin pinned · Drag an ability to where it lands';
    case LineUpPlacementMode.toPinnedLanding:
      if (placement.hasOrigin) {
        return 'Landing spot pinned · Origin placed';
      }
      final agentName =
          AgentData.agents[placement.pinnedAgentType]?.name ?? 'the agent';
      return 'Landing spot pinned · Drag $agentName to where you throw from';
  }
}

class LineupControlButtons extends ConsumerWidget {
  const LineupControlButtons({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final placement = ref.watch(lineUpProvider).placement;
    final interactionState = ref.watch(interactionStateProvider);
    if (interactionState != InteractionState.lineUpPlacing ||
        placement == null) {
      return const SizedBox.shrink();
    }

    final hasOrigin = placement.hasOrigin;
    final hasLanding = placement.hasLanding;
    final tooltipMessage = !hasOrigin && !hasLanding
        ? "Place an agent and ability to continue"
        : !hasOrigin
            ? "Place an agent to continue"
            : !hasLanding
                ? "Place an ability to continue"
                : "Finalize lineup details";

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            key: const ValueKey('lineup-placement-status'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: Settings.abilityBGColor,
              borderRadius: const BorderRadius.all(Radius.circular(4)),
              border: Border.all(
                color: Settings.tacticalVioletTheme.border,
                width: 2,
              ),
              boxShadow: const [Settings.cardForegroundBackdrop],
            ),
            child: Text(
              lineUpPlacementStatus(placement),
              style: TextStyle(
                color: Settings.tacticalVioletTheme.foreground,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 8),
          ShadTooltip(
            builder: (_) => const Text("Cancel"),
            child: ShadIconButton.secondary(
              width: 40,
              height: 40,
              icon: const Icon(LucideIcons.x),
              onPressed: () {
                ref
                    .read(interactionStateProvider.notifier)
                    .update(InteractionState.navigation);
              },
            ),
          ),
          const SizedBox(width: 8),
          ShadTooltip(
            builder: (_) => Text(tooltipMessage),
            child: ShadGestureDetector(
              child: ShadButton(
                trailing: const Icon(LucideIcons.arrowRight),
                enabled: placement.isComplete,
                onPressed: () {
                  showShadDialog(
                    context: context,
                    builder: (dialogContext) {
                      return const CreateLineupDialog();
                    },
                  );
                },
                child: const Text("Next"),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
