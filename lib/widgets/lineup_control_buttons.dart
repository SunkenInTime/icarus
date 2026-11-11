import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/widgets/dialogs/create_lineup_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class LineupControlButtons extends ConsumerWidget {
  const LineupControlButtons({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final interactionState = ref.watch(interactionStateProvider);
    return switch (interactionState) {
      InteractionState.lineUpPlacing => const _PlacingButtons(),
      InteractionState.lineUpEditing => const _EditingButtons(),
      _ => const SizedBox.shrink(),
    };
  }
}

class _PlacingButtons extends ConsumerWidget {
  const _PlacingButtons();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final placement = ref.watch(lineUpProvider).placement;
    if (placement == null) return const SizedBox.shrink();

    final hasOrigin = placement.hasOrigin;
    final hasLanding = placement.hasLanding;
    final l10n = context.l10n;
    final tooltipMessage = !hasOrigin && !hasLanding
        ? l10n.lineupControlPlaceBoth
        : !hasOrigin
            ? l10n.lineupControlPlaceAgent
            : !hasLanding
                ? l10n.lineupControlPlaceAbility
                : l10n.lineupControlFinalize;

    return _ButtonRow(
      primary: ShadTooltip(
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
            child: Text(l10n.lineupControlNext),
          ),
        ),
      ),
    );
  }
}

class _EditingButtons extends ConsumerWidget {
  const _EditingButtons();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final moved = ref.watch(lineUpProvider.select((s) => s.editMovesAnything));
    return _ButtonRow(
      primary: ShadButton(
        key: const ValueKey('lineup-edit-save'),
        enabled: moved,
        onPressed: () {
          ref.read(lineUpProvider.notifier).saveEdit();
          ref
              .read(interactionStateProvider.notifier)
              .update(InteractionState.navigation);
        },
        child: Text(context.l10n.commonSave),
      ),
    );
  }
}

/// Cancel, then the mode's own button, at the bottom right of the map.
class _ButtonRow extends ConsumerWidget {
  const _ButtonRow({required this.primary});

  final Widget primary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ShadTooltip(
            builder: (_) => Text(context.l10n.commonCancel),
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
          primary,
        ],
      ),
    );
  }
}
