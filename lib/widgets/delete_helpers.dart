import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';

void deleteHoveredTarget(WidgetRef ref, HoveredDeleteTarget target) {
  switch (target.type) {
    case DeleteTargetType.agent:
      if (!_agentExists(ref, target.id)) return;
      ref.read(actionProvider.notifier).addAction(
            UserAction(
              type: ActionType.deletion,
              id: target.id,
              group: ActionGroup.agent,
            ),
          );
      ref.read(agentProvider.notifier).removeAgent(target.id);
      return;
    case DeleteTargetType.ability:
      if (!_abilityExists(ref, target.id)) return;
      ref.read(actionProvider.notifier).addAction(
            UserAction(
              type: ActionType.deletion,
              id: target.id,
              group: ActionGroup.ability,
            ),
          );
      ref.read(abilityProvider.notifier).removeAbility(target.id);
      return;
    case DeleteTargetType.text:
      if (!_textExists(ref, target.id)) return;
      ref.read(actionProvider.notifier).addAction(
            UserAction(
              type: ActionType.deletion,
              id: target.id,
              group: ActionGroup.text,
            ),
          );
      ref.read(textProvider.notifier).removeText(target.id);
      return;
    case DeleteTargetType.image:
      if (!_imageExists(ref, target.id)) return;
      ref.read(actionProvider.notifier).addAction(
            UserAction(
              type: ActionType.deletion,
              id: target.id,
              group: ActionGroup.image,
            ),
          );
      ref.read(placedImageProvider.notifier).removeImage(target.id);
      return;
    case DeleteTargetType.utility:
      if (!_utilityExists(ref, target.id)) return;
      ref.read(actionProvider.notifier).addAction(
            UserAction(
              type: ActionType.deletion,
              id: target.id,
              group: ActionGroup.utility,
            ),
          );
      ref.read(utilityProvider.notifier).removeUtility(target.id);
      return;
    case DeleteTargetType.lineup:
      if (!_lineUpExists(ref, target.id)) return;
      ref.read(lineUpProvider.notifier).deleteLineUpById(target.id);
      return;
  }
}

void deletePlacedWidget(WidgetRef ref, PlacedWidget placedData) {
  if (placedData is PlacedAgent) {
    final action = UserAction(
      type: ActionType.deletion,
      id: placedData.id,
      group: ActionGroup.agent,
    );
    ref.read(agentProvider.notifier).removeAgent(placedData.id);
    ref.read(actionProvider.notifier).addAction(action);
  } else if (placedData is PlacedAbility) {
    final action = UserAction(
      type: ActionType.deletion,
      id: placedData.id,
      group: ActionGroup.ability,
    );
    ref.read(abilityProvider.notifier).removeAbility(placedData.id);
    ref.read(actionProvider.notifier).addAction(action);
  } else if (placedData is PlacedText) {
    final action = UserAction(
      type: ActionType.deletion,
      id: placedData.id,
      group: ActionGroup.text,
    );
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
}

bool _agentExists(WidgetRef ref, String id) {
  return ref.read(agentProvider).any((agent) => agent.id == id);
}

bool _abilityExists(WidgetRef ref, String id) {
  return ref.read(abilityProvider).any((ability) => ability.id == id);
}

bool _textExists(WidgetRef ref, String id) {
  return ref.read(textProvider).any((text) => text.id == id);
}

bool _imageExists(WidgetRef ref, String id) {
  return ref.read(placedImageProvider).images.any((image) => image.id == id);
}

bool _utilityExists(WidgetRef ref, String id) {
  return ref.read(utilityProvider).any((utility) => utility.id == id);
}

bool _lineUpExists(WidgetRef ref, String id) {
  return ref.read(lineUpProvider).lineUps.any((lineUp) => lineUp.id == id);
}
