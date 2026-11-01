import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';

void deleteHoveredTarget(WidgetRef ref, HoveredDeleteTarget target) {
  switch (target.type) {
    case DeleteTargetType.agent:
      _removePlacedAgent(ref, target.id);
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
      final lineUps = ref.read(lineUpProvider.notifier);
      if (lineUps.originById(target.id) != null) {
        lineUps.deleteOrigin(target.id);
      } else if (lineUps.landingById(target.id) != null) {
        lineUps.deleteLanding(target.id);
      }
      return;
  }
}

void deletePlacedWidget(WidgetRef ref, PlacedWidget placedData) {
  if (placedData is PlacedAgentNode) {
    _removePlacedAgent(ref, placedData.id);
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

/// Removes a placed agent from the page. A lineup mode keeps the page out of
/// reach, so an agent acted on there is a draft, and a draft from Create Lineup
/// has the id of the placed agent it started from.
void _removePlacedAgent(WidgetRef ref, String id) {
  if (ref.read(interactionStateProvider).isLineUpMode) return;
  ref.read(agentProvider.notifier).removeAgentAsAction(id);
}
