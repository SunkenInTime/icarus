import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/ability_bar_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/team_provider.dart';
import 'package:icarus/widgets/current_line_up_painter.dart';
import 'package:icarus/widgets/draggable_widgets/ability/placed_ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/agents/placed_lineup_agent_widget.dart';
import 'package:icarus/widgets/line_up_widget.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:uuid/uuid.dart';

/// The one thing the user has to do next. Empty once both ends are down.
String lineUpPlacementStatus(LineUpPlacement placement) {
  if (placement.isComplete) return '';
  switch (placement.mode) {
    case LineUpPlacementMode.fresh:
      return placement.hasOrigin
          ? 'Drag the ability to where it lands'
          : 'Drag an agent to where you throw from';
    case LineUpPlacementMode.fromPinnedOrigin:
      return 'Drag the ability to where it lands';
    case LineUpPlacementMode.toPinnedLanding:
      final agentName =
          AgentData.agents[placement.pinnedAgentType]?.name ?? 'the agent';
      return 'Drag $agentName to where you throw from';
  }
}

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
        final lineUpState = ref.watch(lineUpProvider);
        final placement = lineUpState.placement;
        final draftAgent = placement?.draftAgent;
        final draftAbility = placement?.draftAbility;
        final pinnedOrigin =
            lineUpState.originById(placement?.pinnedOriginId ?? '');
        final pinnedLanding =
            lineUpState.landingById(placement?.pinnedLandingId ?? '');

        Offset localOffset(Offset globalOffset) {
          final renderBox = context.findRenderObject() as RenderBox;
          return renderBox.globalToLocal(globalOffset);
        }

        PlacedAgent agentAt(AgentData data, Offset renderedTopLeft) {
          return PlacedAgent(
            id: const Uuid().v4(),
            type: data.type,
            position: storedAgentPositionForRenderedScreenPosition(
              coordinateSystem: coordinateSystem,
              renderedScreenPosition: renderedTopLeft,
              agentSize: ref.read(strategySettingsProvider).agentSize,
              isAttack: ref.read(mapProvider).isAttack,
            ),
            isAlly: ref.read(teamProvider),
          );
        }

        PlacedAbility abilityAt(AbilityInfo info, Offset renderedTopLeft) {
          return PlacedAbility(
            id: const Uuid().v4(),
            data: info,
            position: storedAbilityPositionForRenderedScreenPosition(
              ability: info.abilityData!,
              coordinateSystem: coordinateSystem,
              renderedScreenPosition: renderedTopLeft,
              mapScale: Maps.mapScale[ref.read(mapProvider).currentMap] ?? 1.0,
              abilitySize: ref.read(strategySettingsProvider).abilitySize,
              isAttack: ref.read(mapProvider).isAttack,
            ),
            isAlly: ref.read(teamProvider),
          );
        }

        /// Which end the dragged item would become and where its anchor ends
        /// up if dropped at this offset, so the preview line points at the
        /// real landing point rather than the corner of the drag feedback.
        /// Sidebar items and drafts being repositioned both count.
        LineUpDragHover? dropHover(Object? data, Offset renderedTopLeft) {
          final isAttack = ref.read(mapProvider).isAttack;
          final PlacedAgent? agent = switch (data) {
            AgentData() => agentAt(data, renderedTopLeft),
            PlacedAgent() => agentAt(
                AgentData.agents[data.type]!,
                renderedTopLeft,
              ),
            _ => null,
          };
          if (agent != null) {
            return LineUpDragHover(
              end: LineUpEnd.origin,
              anchor: screenAnchorForAgent(
                agent: agent,
                coordinateSystem: coordinateSystem,
                isAttack: isAttack,
              ),
            );
          }
          final PlacedAbility? ability = switch (data) {
            AbilityInfo() => abilityAt(data, renderedTopLeft),
            PlacedAbility() => abilityAt(data.data, renderedTopLeft),
            _ => null,
          };
          if (ability != null) {
            return LineUpDragHover(
              end: LineUpEnd.landing,
              anchor: screenAnchorForAbility(
                ability: ability,
                coordinateSystem: coordinateSystem,
                mapScale:
                    Maps.mapScale[ref.read(mapProvider).currentMap] ?? 1.0,
                isAttack: isAttack,
              ),
            );
          }
          return null;
        }

        return DragTarget(
          builder: (context, candidateData, rejectedData) {
            return Stack(
              children: [
                const Positioned.fill(child: CurrentLineUpPainter()),
                if (pinnedOrigin != null)
                  LineUpOriginAgentWidget(
                    origin: pinnedOrigin,
                    interactive: false,
                  ),
                if (pinnedLanding != null)
                  LineUpLandingAbilityWidget(
                    landing: pinnedLanding,
                    interactive: false,
                  ),
                if (placement != null && !placement.isComplete)
                  Align(
                    alignment: Alignment.center,
                    child: IgnorePointer(
                      child: Container(
                        key: const ValueKey('lineup-placement-status'),
                        margin: const EdgeInsets.all(16),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Settings.tacticalVioletTheme.primary,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Settings.tacticalVioletTheme.border,
                          ),
                          boxShadow: const [Settings.cardForegroundBackdrop],
                        ),
                        child: Text(
                          lineUpPlacementStatus(placement),
                          style: ShadTheme.of(context)
                              .textTheme
                              .small
                              .copyWith(color: Colors.white),
                        ),
                      ),
                    ),
                  ),
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
                .update(dropHover(details.data, localOffset(details.offset)));
          },
          onLeave: (_) {
            ref.read(lineUpDragHoverProvider.notifier).update(null);
          },
          onAcceptWithDetails: (details) {
            ref.read(lineUpDragHoverProvider.notifier).update(null);
            final dropOffset = localOffset(details.offset);
            final data = details.data;

            if (data is AgentData) {
              ref
                  .read(lineUpProvider.notifier)
                  .setDraftAgent(agentAt(data, dropOffset));
              final lockedType =
                  ref.read(lineUpProvider).placement?.lockedAgentType;
              if (lockedType != null) {
                ref
                    .read(abilityBarProvider.notifier)
                    .updateData(AgentData.agents[lockedType]!);
              }
            } else if (data is AbilityInfo) {
              ref
                  .read(lineUpProvider.notifier)
                  .setDraftAbility(abilityAt(data, dropOffset));
            }
          },
        );
      },
    );
  }
}
