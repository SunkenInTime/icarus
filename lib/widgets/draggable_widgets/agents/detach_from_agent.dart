import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:uuid/uuid.dart';

/// Splits the circle or cone attached to [agent] off as a free item drawn on
/// the same spot, leaving a plain agent: the reverse of dropping one on an
/// agent. One undo step. [read] is a WidgetRef's or a container's.
void detachFromAgent(
  T Function<T>(ProviderListenable<T> provider) read,
  PlacedAgentNode agent,
) {
  final free = switch (agent) {
    PlacedCircleAgent() => PlacedUtility(
        id: const Uuid().v4(),
        type: UtilityType.customCircle,
        position: Offset.zero,
        customDiameter: agent.diameterMeters,
        customColorValue: agent.colorValue,
        customOpacityPercent: agent.opacityPercent,
      ),
    PlacedViewConeAgent() => PlacedUtility(
        id: const Uuid().v4(),
        type: agent.presetType,
        position: Offset.zero,
        angle: UtilityData.getViewConeAngle(agent.presetType),
        visionElevation: agent.visionElevation,
      )
        ..rotation = agent.rotation
        ..length = agent.length,
    PlacedAgent() => null,
  };
  if (free == null) return;

  // Both are drawn around the agent's middle, and the free item's position is
  // the top-left that puts its own anchor there.
  final coordinateSystem = CoordinateSystem.instance;
  final mapScale = Maps.mapScale[read(mapProvider).currentMap] ?? 1.0;
  final middle =
      agent.position + coordinateSystem.virtualOffsetToWorld(storedAgentAnchor);
  free.position = middle -
      coordinateSystem.virtualOffsetToWorld(
        storedUtilityAnchor(utility: free, mapScale: mapScale),
      );

  read(actionProvider.notifier).performTransaction(
    groups: const [ActionGroup.agent, ActionGroup.utility],
    mutation: () {
      final agents = read(agentProvider.notifier);
      final converted = agent is PlacedCircleAgent
          ? agents.convertCircleAgentToPlain(id: agent.id)
          : agents.convertViewConeAgentToPlain(id: agent.id);
      if (converted) read(utilityProvider.notifier).addUtility(free);
    },
  );
}
