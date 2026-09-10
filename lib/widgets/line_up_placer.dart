import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/ability_bar_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/team_provider.dart';
import 'package:icarus/widgets/current_line_up_painter.dart';
import 'package:icarus/widgets/draggable_widgets/ability/placed_ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/agents/placed_lineup_agent_widget.dart';
import 'package:uuid/uuid.dart';

class LineupPositionWidget extends ConsumerStatefulWidget {
  const LineupPositionWidget({super.key});

  @override
  ConsumerState<LineupPositionWidget> createState() =>
      _LineupPositionWidgetState();
}

class _LineupPositionWidgetState extends ConsumerState<LineupPositionWidget> {
  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;

    return LayoutBuilder(
      builder: (context, constraints) {
        final placement = ref.watch(lineUpProvider).placement;
        final draftAgent = placement?.draftAgent;
        final draftAbility = placement?.draftAbility;

        Offset localOffset(Offset globalOffset) {
          final renderBox = context.findRenderObject() as RenderBox;
          return renderBox.globalToLocal(globalOffset);
        }

        return DragTarget(
          builder: (context, candidateData, rejectedData) {
            return Stack(
              children: [
                const Positioned.fill(child: CurrentLineUpPainter()),
                if (draftAbility != null)
                  PlacedAbilityWidget(
                    rotation: draftAbility.rotation,
                    data: draftAbility,
                    ability: draftAbility,
                    id: draftAbility.id,
                    length: draftAbility.length,
                    isLineUp: true,
                    onDragEnd: (details, _) {
                      final mapState = ref.read(mapProvider);
                      final mapScale =
                          Maps.mapScale[mapState.currentMap] ?? 1.0;
                      final abilitySize =
                          ref.read(strategySettingsProvider).abilitySize;

                      final abilityData = draftAbility.data.abilityData!;
                      final virtualOffset =
                          storedAbilityPositionForRenderedScreenPosition(
                        ability: abilityData,
                        coordinateSystem: coordinateSystem,
                        renderedScreenPosition: localOffset(details.offset),
                        mapScale: mapScale,
                        abilitySize: abilitySize,
                        isAttack: mapState.isAttack,
                      );
                      final safeArea = storedAbilityAnchor(
                        ability: abilityData,
                        mapScale: mapScale,
                      );

                      if (coordinateSystem.isOutOfBounds(
                        virtualOffset.translate(safeArea.dx, safeArea.dy),
                      )) {
                        ref.read(lineUpProvider.notifier).clearDraftAbility();
                        return;
                      }

                      ref
                          .read(lineUpProvider.notifier)
                          .updateDraftAbilityPosition(virtualOffset);
                    },
                  ),
                if (draftAgent != null)
                  PlacedLineupAgentWidget(
                    agent: draftAgent,
                    draggable: true,
                    onDragEnd: (details) {
                      final virtualOffset =
                          storedAgentPositionForRenderedScreenPosition(
                        coordinateSystem: coordinateSystem,
                        renderedScreenPosition: localOffset(details.offset),
                        agentSize: ref.read(strategySettingsProvider).agentSize,
                        isAttack: ref.read(mapProvider).isAttack,
                      );

                      ref
                          .read(lineUpProvider.notifier)
                          .updateDraftAgentPosition(virtualOffset);
                    },
                  ),
              ],
            );
          },
          onMove: (details) {
            ref
                .read(lineUpDragHoverProvider.notifier)
                .update(localOffset(details.offset));
          },
          onLeave: (_) {
            ref.read(lineUpDragHoverProvider.notifier).update(null);
          },
          onAcceptWithDetails: (details) {
            ref.read(lineUpDragHoverProvider.notifier).update(null);
            final dropOffset = localOffset(details.offset);
            const uuid = Uuid();

            if (details.data is AgentData) {
              final agentPosition =
                  storedAgentPositionForRenderedScreenPosition(
                coordinateSystem: coordinateSystem,
                renderedScreenPosition: dropOffset,
                agentSize: ref.read(strategySettingsProvider).agentSize,
                isAttack: ref.read(mapProvider).isAttack,
              );
              final placedAgent = PlacedAgent(
                id: uuid.v4(),
                type: (details.data as AgentData).type,
                position: agentPosition,
                isAlly: ref.read(teamProvider),
              );

              ref.read(lineUpProvider.notifier).setDraftAgent(placedAgent);
              final lockedType =
                  ref.read(lineUpProvider).placement?.lockedAgentType;
              if (lockedType != null) {
                ref
                    .read(abilityBarProvider.notifier)
                    .updateData(AgentData.agents[lockedType]!);
              }
            } else if (details.data is AbilityInfo) {
              final abilityInfo = details.data as AbilityInfo;
              final abilityPosition =
                  storedAbilityPositionForRenderedScreenPosition(
                ability: abilityInfo.abilityData!,
                coordinateSystem: coordinateSystem,
                renderedScreenPosition: dropOffset,
                mapScale:
                    Maps.mapScale[ref.read(mapProvider).currentMap] ?? 1.0,
                abilitySize: ref.read(strategySettingsProvider).abilitySize,
                isAttack: ref.read(mapProvider).isAttack,
              );
              final placedAbility = PlacedAbility(
                id: uuid.v4(),
                data: abilityInfo,
                position: abilityPosition,
                isAlly: ref.read(teamProvider),
              );

              ref.read(lineUpProvider.notifier).setDraftAbility(placedAbility);
            }
          },
        );
      },
    );
  }
}
