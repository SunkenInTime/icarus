import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_visibility_context_menu.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';

class LineUpGroupAgentWidget extends ConsumerWidget {
  const LineUpGroupAgentWidget({super.key, required this.group});

  final LineUpGroup group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final agentScreen = coordinateSystem.coordinateToScreen(group.agent.position);

    return Positioned(
      key: ValueKey('lineup-agent-${group.id}'),
      left: agentScreen.dx,
      top: agentScreen.dy,
      child: AgentWidget(
        lineUpId: group.id,
        agent: AgentData.agents[group.agent.type]!,
        isAlly: group.agent.isAlly,
        id: group.agent.id,
      ),
    );
  }
}

class LineUpItemAbilityWidget extends ConsumerWidget {
  const LineUpItemAbilityWidget({
    super.key,
    required this.groupId,
    required this.item,
  });

  final String groupId;
  final LineUpItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final currentMap =
        ref.watch(mapProvider.select((state) => state.currentMap));
    final mapScale = Maps.mapScale[currentMap] ?? 1.0;
    final abilityScreen =
        coordinateSystem.coordinateToScreen(item.ability.position);
    final isRotatable = item.ability.rotation != 0;
    final abilitySize = ref.watch(strategySettingsProvider).abilitySize;
    final contextMenuItems = buildAbilityContextMenuItems(
      ref,
      item.ability,
      lineUpGroupId: groupId,
      lineUpItemId: item.id,
      includeDelete: true,
    );
    final rawAbilityChild = isRotatable
        ? Transform.rotate(
            angle: item.ability.rotation,
            alignment: Alignment.topLeft,
            origin: item.ability.data.abilityData!
                .getAnchorPoint(mapScale: mapScale, abilitySize: abilitySize)
                .scale(
                  coordinateSystem.scaleFactor,
                  coordinateSystem.scaleFactor,
                ),
            child: item.ability.data.abilityData!.createWidget(
              id: null,
              isAlly: item.ability.isAlly,
              mapScale: mapScale,
              lineUpId: groupId,
              lineUpItemId: item.id,
              rotation: item.ability.rotation,
              length: item.ability.length,
              armLengthsMeters: item.ability.armLengthsMeters,
              visualState: item.ability.visualState,
              watchMouse: true,
              contextMenuItems: contextMenuItems,
            ),
          )
        : item.ability.data.abilityData!.createWidget(
            id: null,
            isAlly: item.ability.isAlly,
            mapScale: mapScale,
            lineUpId: groupId,
            lineUpItemId: item.id,
            rotation: item.ability.rotation,
            length: item.ability.length,
            armLengthsMeters: item.ability.armLengthsMeters,
            visualState: item.ability.visualState,
            watchMouse: true,
            contextMenuItems: contextMenuItems,
          );
    return Positioned(
      key: ValueKey('lineup-ability-${item.id}'),
      left: abilityScreen.dx,
      top: abilityScreen.dy,
      child: rawAbilityChild,
    );
  }
}

@Deprecated('Use LineUpGroupAgentWidget instead.')
class LineUpAgentWidget extends StatelessWidget {
  const LineUpAgentWidget({super.key, required this.lineUp});

  final LineUp lineUp;

  @override
  Widget build(BuildContext context) {
    return LineUpGroupAgentWidget(
      group: LineUpGroup.fromLegacyLineUp(lineUp),
    );
  }
}

@Deprecated('Use LineUpItemAbilityWidget instead.')
class LineUpAbilityWidget extends StatelessWidget {
  const LineUpAbilityWidget({super.key, required this.lineUp});

  final LineUp lineUp;

  @override
  Widget build(BuildContext context) {
    return LineUpItemAbilityWidget(
      groupId: lineUp.id,
      item: LineUpGroup.fromLegacyLineUp(lineUp).items.single,
    );
  }
}
