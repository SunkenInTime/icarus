import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/ability_bar_provider.dart';

import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/team_provider.dart';
import 'package:icarus/widgets/custom_button.dart';
import 'package:icarus/widgets/dialogs/create_lineup_dialog.dart';
import 'package:icarus/widgets/draggable_widgets/ability/placed_ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';
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

    // log(ref.watch(mapProvider).isAttack.toString());
    return LayoutBuilder(builder: (context, constraints) {
      final lineUp = ref.watch(lineUpProvider);
      return DragTarget(
        builder: (context, candidateData, rejectedData) {
          return Stack(
            children: [
              if (lineUp.currentAbility != null)
                PlacedAbilityWidget(
                  rotation: lineUp.currentAbility!.rotation,
                  data: lineUp.currentAbility!,
                  ability: lineUp.currentAbility!,
                  id: lineUp.currentAbility!.id,
                  length: lineUp.currentAbility!.length,
                  isLineUp: true,
                  onDragEnd: (details) {
                    RenderBox renderBox =
                        context.findRenderObject() as RenderBox;
                    Offset localOffset =
                        renderBox.globalToLocal(details.offset);
                    // Updating info

                    final mapScale = ref.read(mapProvider.notifier).mapScale;
                    final abilitySize =
                        ref.read(strategySettingsProvider).abilitySize;

                    Offset virtualOffset =
                        coordinateSystem.screenToCoordinate(localOffset);
                    Offset safeArea = lineUp.currentAbility!.data.abilityData!
                        .getAnchorPoint(
                            mapScale: mapScale, abilitySize: abilitySize);

                    if (coordinateSystem.isOutOfBounds(
                        virtualOffset.translate(safeArea.dx, safeArea.dy))) {
                      //TODO: Fix removal of ability
                      return;
                    }

                    log(renderBox.size.toString());

                    ref.read(lineUpProvider.notifier).updateAbilityPosition(
                        coordinateSystem.screenToCoordinate(localOffset));
                  },
                ),
              if (lineUp.currentAgent != null)
                Positioned(
                  left: coordinateSystem
                      .coordinateToScreen(lineUp.currentAgent!.position)
                      .dx,
                  top: coordinateSystem
                      .coordinateToScreen(lineUp.currentAgent!.position)
                      .dy,
                  child: Draggable<PlacedWidget>(
                    data: lineUp.currentAgent,
                    dragAnchorStrategy: ref
                        .read(screenZoomProvider.notifier)
                        .zoomDragAnchorStrategy,
                    feedback: Opacity(
                      opacity: Settings.feedbackOpacity,
                      child: ZoomTransform(
                        child: AgentWidget(
                          isAlly: lineUp.currentAgent!.isAlly,
                          id: "",
                          agent: AgentData.agents[lineUp.currentAgent!.type]!,
                        ),
                      ),
                    ),
                    childWhenDragging: const SizedBox.shrink(),
                    onDragEnd: (details) {
                      RenderBox renderBox =
                          context.findRenderObject() as RenderBox;
                      Offset localOffset =
                          renderBox.globalToLocal(details.offset);

                      //Basically makes sure that if more than half is of the screen it gets deleted
                      Offset virtualOffset =
                          coordinateSystem.screenToCoordinate(localOffset);

                      ref
                          .read(lineUpProvider.notifier)
                          .updateAgentPosition(virtualOffset);
                    },
                    child: RepaintBoundary(
                      child: AgentWidget(
                        isAlly: lineUp.currentAgent!.isAlly,
                        id: lineUp.currentAgent!.id,
                        agent: AgentData.agents[lineUp.currentAgent!.type]!,
                      ),
                    ),
                  ),
                ),
              Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: CustomButton(
                    icon: const Icon(Icons.arrow_forward),
                    isDynamicWidth: true,
                    isIconRight: true,
                    label: "Next",
                    isDisabled: lineUp.currentAgent == null ||
                        lineUp.currentAbility == null,
                    disabledTooltip: lineUp.currentAgent == null
                        ? "Place an agent to continue"
                        : lineUp.currentAbility == null
                            ? "Place an ability to continue"
                            : null,
                    height: 40,
                    // width: 140,
                    onPressed: () {
                      // ref.read(lineUpProvider.notifier).clearCurrentPlacing();
                      showDialog(
                        context: context,
                        builder: (dialogContext) {
                          return const CreateLineupDialog();
                        },
                      );
                    },
                  ),
                ),
              )
            ],
          );
        },
        onAcceptWithDetails: (details) {
          RenderBox renderBox = context.findRenderObject() as RenderBox;
          Offset localOffset = renderBox.globalToLocal(details.offset);
          Offset normalizedPosition =
              coordinateSystem.screenToCoordinate(localOffset);
          const uuid = Uuid();

          if (details.data is AgentData) {
            PlacedAgent placedAgent = PlacedAgent(
              id: uuid.v4(),
              type: (details.data as AgentData).type,
              position: normalizedPosition,
              isAlly: ref.read(teamProvider),
            );

            ref.read(lineUpProvider.notifier).setAgent(placedAgent);
            ref
                .read(abilityBarProvider.notifier)
                .updateData(AgentData.agents[placedAgent.type]!);
          } else if (details.data is AbilityInfo) {
            PlacedAbility placedAbility = PlacedAbility(
              id: uuid.v4(),
              data: details.data as AbilityInfo,
              position: normalizedPosition,
              isAlly: ref.read(teamProvider),
            );

            ref.read(lineUpProvider.notifier).setAbility(placedAbility);
          }
        },
        onLeave: (data) {
          log("I have left");
        },
      );
    });
  }
}
