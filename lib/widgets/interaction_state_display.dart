import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Displays the current interaction state in a toast-like pill.
class InteractionStateDisplay extends ConsumerWidget {
  const InteractionStateDisplay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final interactionState = ref.watch(interactionStateProvider);
    final message = _messageForState(interactionState);

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Settings.tacticalVioletTheme.border,
        ),
      ),
      child: Text(
        message,
        style:
            ShadTheme.of(context).textTheme.small.copyWith(color: Colors.white),
      ),
    );
  }

  String _messageForState(InteractionState state) {
    switch (state) {
      case InteractionState.navigation:
        return 'Navigation Mode';
      case InteractionState.drawing:
        return 'Drawing in Progress';
      case InteractionState.erasing:
        return 'Erasing Selection';
      case InteractionState.deleting:
        return 'Delete Mode';
      case InteractionState.lineUpPlacing:
        return 'Placing Lineup';
    }
  }
}
