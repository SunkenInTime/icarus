import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/widgets/dialogs/create_lineup_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class LineupControlButtons extends ConsumerWidget {
  const LineupControlButtons({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lineUp = ref.watch(lineUpProvider);
    final interactionState = ref.watch(interactionStateProvider);
    return interactionState == InteractionState.lineUpPlacing
        ? Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
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
                Builder(
                  builder: (context) {
                    final hasAgent = lineUp.currentAgent != null;
                    final hasAbility = lineUp.currentAbility != null;
                    final isDisabled = !hasAgent || !hasAbility;
                    final tooltipMessage = !hasAgent && !hasAbility
                        ? "Place an agent and ability to continue"
                        : !hasAgent
                            ? "Place an agent to continue"
                            : !hasAbility
                                ? "Place an ability to continue"
                                : "Finalize lineup details";

                    return ShadTooltip(
                      builder: (_) => Text(tooltipMessage),
                      child: ShadGestureDetector(
                        child: ShadButton(
                          trailing: const Icon(LucideIcons.arrowRight),
                          enabled: !isDisabled,
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
                    );
                  },
                ),
              ],
            ),
          )
        : const SizedBox.shrink();
  }
}
