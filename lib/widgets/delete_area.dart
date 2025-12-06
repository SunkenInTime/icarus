import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';

class DeleteArea extends ConsumerWidget {
  const DeleteArea({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref.watch(screenshotProvider)
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.all(16.0),
            child: SizedBox(
              height: 70,
              width: 70,
              child: DragTarget(
                builder: (context, candidateData, rejectedData) {
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    decoration: BoxDecoration(
                      color: candidateData.isNotEmpty
                          ? Settings.tacticalVioletTheme.destructive
                          : Settings.tacticalVioletTheme.destructive
                              .withOpacity(0.1),
                      border: Border.all(
                        color: candidateData.isNotEmpty
                            ? Settings.tacticalVioletTheme.destructive
                            : Settings.tacticalVioletTheme.destructive
                                .withOpacity(0.2),
                        width: 2,
                      ),
                    ),
                    child: Icon(
                      color: candidateData.isNotEmpty
                          ? Settings.tacticalVioletTheme.foreground
                          : Settings.tacticalVioletTheme.destructive,
                      Icons.delete_outline,
                      size: 24,
                      // color: Color.fromARGB(255, 245, 245, 245),
                    ),
                  );
                },
                onAcceptWithDetails: (dragData) {
                  final placedData = dragData.data;

                  if (placedData is PlacedAgent) {
                    final action = UserAction(
                        type: ActionType.deletion,
                        id: placedData.id,
                        group: ActionGroup.agent);
                    ref.read(agentProvider.notifier).removeAgent(placedData.id);
                    ref.read(actionProvider.notifier).addAction(action);
                  } else if (placedData is PlacedAbility) {
                    final action = UserAction(
                        type: ActionType.deletion,
                        id: placedData.id,
                        group: ActionGroup.ability);
                    ref
                        .read(abilityProvider.notifier)
                        .removeAbility(placedData.id);
                    ref.read(actionProvider.notifier).addAction(action);
                  } else if (placedData is PlacedText) {
                    final action = UserAction(
                        type: ActionType.deletion,
                        id: placedData.id,
                        group: ActionGroup.text);
                    ref.read(textProvider.notifier).removeText(placedData.id);
                    ref.read(actionProvider.notifier).addAction(action);
                  } else if (placedData is PlacedImage) {
                    final action = UserAction(
                      type: ActionType.deletion,
                      id: placedData.id,
                      group: ActionGroup.image,
                    );
                    ref
                        .read(placedImageProvider.notifier)
                        .removeImage(placedData.id);
                    ref.read(actionProvider.notifier).addAction(action);
                  } else if (placedData is PlacedUtility) {
                    final action = UserAction(
                      type: ActionType.deletion,
                      id: placedData.id,
                      group: ActionGroup.utility,
                    );
                    ref
                        .read(utilityProvider.notifier)
                        .removeUtility(placedData.id);
                    ref.read(actionProvider.notifier).addAction(action);
                  }
                },
              ),
            ),
          );
  }
}
