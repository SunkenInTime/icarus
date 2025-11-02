import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';

class DeleteCapture extends ConsumerWidget {
  const DeleteCapture({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DragTarget<PlacedWidget>(
      builder: (context, candidateData, rejectedData) {
        return const SizedBox.expand();
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
          ref.read(abilityProvider.notifier).removeAbility(placedData.id);
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
          ref.read(placedImageProvider.notifier).removeImage(placedData.id);
          ref.read(actionProvider.notifier).addAction(action);
        } else if (placedData is PlacedUtility) {
          final action = UserAction(
            type: ActionType.deletion,
            id: placedData.id,
            group: ActionGroup.utility,
          );
          ref.read(utilityProvider.notifier).removeUtility(placedData.id);
          ref.read(actionProvider.notifier).addAction(action);
        }
      },
    );
  }
}
