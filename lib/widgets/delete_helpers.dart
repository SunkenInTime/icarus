import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';

void deleteHoveredTarget(WidgetRef ref, HoveredDeleteTarget target) {
  switch (target.type) {
    case DeleteTargetType.agent:
      ref.read(agentProvider.notifier).removeAgentAsAction(target.id);
      return;
    case DeleteTargetType.ability:
      ref.read(abilityProvider.notifier).removeAbilityAsAction(target.id);
      return;
    case DeleteTargetType.text:
      ref.read(textProvider.notifier).removeTextAsAction(target.id);
      return;
    case DeleteTargetType.image:
      ref.read(placedImageProvider.notifier).removeImageAsAction(target.id);
      return;
    case DeleteTargetType.utility:
      ref.read(utilityProvider.notifier).removeUtilityAsAction(target.id);
      return;
    case DeleteTargetType.lineup:
      final lineUps = ref.read(lineUpProvider);
      final exists = lineUps.any((lineUp) => lineUp.id == target.id);
      if (exists) {
        ref.read(lineUpProvider.notifier).deleteLineUpById(target.id);
      }
      return;
  }
}

void deletePlacedWidget(WidgetRef ref, PlacedWidget placedData) {
  if (placedData is PlacedAgentNode) {
    ref.read(agentProvider.notifier).removeAgentAsAction(placedData.id);
  } else if (placedData is PlacedAbility) {
    ref.read(abilityProvider.notifier).removeAbilityAsAction(placedData.id);
  } else if (placedData is PlacedText) {
    ref.read(textProvider.notifier).removeTextAsAction(placedData.id);
  } else if (placedData is PlacedImage) {
    ref.read(placedImageProvider.notifier).removeImageAsAction(placedData.id);
  } else if (placedData is PlacedUtility) {
    ref.read(utilityProvider.notifier).removeUtilityAsAction(placedData.id);
  }
}
