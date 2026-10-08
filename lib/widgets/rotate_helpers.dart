import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/ability_vision.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/utility_provider.dart';

/// One press turns an item an eighth of a turn: icons point along the eight
/// compass directions, where a free angle would look like a slip.
const double rotationStep = math.pi / 4;

/// The next eighth of a turn from [rotation]. An angle between steps, left by
/// a rotation handle, lands on the nearest step in the turning direction.
/// A full turn comes back as 2 pi, never 0: 0 marks an icon nobody turned
/// (see uprightGlyphRotation).
double steppedRotation(double rotation, {required bool clockwise}) {
  const epsilon = 1e-6;
  final steps = rotation / rotationStep;
  final next =
      clockwise ? (steps + epsilon).floor() + 1 : (steps - epsilon).ceil() - 1;
  final eighths = next % 8;
  return (eighths == 0 ? 8 : eighths) * rotationStep;
}

/// Turns the hovered item one step. Items whose rotation doesn't show on the
/// map (agents, text, images, round abilities) are left alone.
void rotateHoveredTarget(
  WidgetRef ref,
  HoveredDeleteTarget target, {
  required bool clockwise,
}) {
  switch (target.type) {
    case DeleteTargetType.ability:
      final abilities = ref.read(abilityProvider);
      final index = PlacedWidget.getIndexByID(target.id, abilities);
      if (index < 0 || !_abilityShowsRotation(abilities[index])) return;
      final ability = abilities[index];
      // Step from the angle on screen, so an unturned icon on defense turns
      // from upright rather than from the half turn it is drawn under.
      final from = turnsGlyph(ability.data.abilityData!)
          ? uprightGlyphRotation(
              ability.rotation,
              isAttack: ref.read(mapProvider).isAttack,
            )
          : ability.rotation;
      ref.read(abilityProvider.notifier).updateGeometry(
            index,
            rotation: steppedRotation(from, clockwise: clockwise),
          );
      return;
    case DeleteTargetType.utility:
      final utilities = ref.read(utilityProvider);
      final index = PlacedWidget.getIndexByID(target.id, utilities);
      if (index < 0) return;
      final utility = utilities[index];
      if (!UtilityData.usesRotation(utility.type)) return;
      ref.read(utilityProvider.notifier).updateRotation(
            index,
            steppedRotation(utility.rotation, clockwise: clockwise),
            utility.length,
          );
      return;
    case DeleteTargetType.agent:
      final agents = ref.read(agentProvider);
      final index = PlacedWidget.getIndexByID(target.id, agents);
      if (index < 0) return;
      final agent = agents[index];
      if (agent is! PlacedViewConeAgent) return;
      ref.read(agentProvider.notifier).updateViewConeGeometry(
            id: agent.id,
            rotation: steppedRotation(agent.rotation, clockwise: clockwise),
            length: agent.length,
          );
      return;
    case DeleteTargetType.text:
    case DeleteTargetType.image:
    case DeleteTargetType.lineup:
      return;
  }
}

bool _abilityShowsRotation(PlacedAbility ability) {
  final data = ability.data.abilityData;
  if (data == null) return false;
  if (AbilityVisionConeSpec.forAbility(ability.data) != null) {
    return ability.visualState.showVisionCone;
  }
  return isRotatable(data) || turnsGlyph(data);
}
