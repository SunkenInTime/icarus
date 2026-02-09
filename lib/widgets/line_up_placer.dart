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
import 'package:icarus/widgets/current_line_up_painter.dart';
import 'package:icarus/widgets/custom_button.dart';
import 'package:icarus/widgets/dialogs/create_lineup_dialog.dart';
import 'package:icarus/widgets/draggable_widgets/ability/placed_ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
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
              const Positioned.fill(
                child: CurrentLineUpPainter(),
              ),
              if (lineUp.currentAgent == null)
                Align(
                  alignment: Alignment.center,
                  child: Container(
                    margin: const EdgeInsets.all(16),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Settings.tacticalVioletTheme.primary,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Settings.tacticalVioletTheme.border,
                      ),
                      boxShadow: const [Settings.cardForegroundBackdrop],
                    ),
                    child: Text(
                      "Drag an agent to the map to start placing",
                      style: ShadTheme.of(context)
                          .textTheme
                          .small
                          .copyWith(color: Colors.white),
                    ),
                  ),
                ),
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
                          agent: AgentData.forType(lineUp.currentAgent!.type)!,
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
                        agent: AgentData.forType(lineUp.currentAgent!.type)!,
                      ),
                    ),
                  ),
                ),
              Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ShadTooltip(
                        builder: (_) => const Text("Cancel"),
                        child: ShadIconButton.secondary(
                          width: 40,
                          height: 40,
                          icon: const Icon(LucideIcons.x),
                          onPressed: () {
                            ref
                                .read(interactionStateProvider.notifier)
                                .update(InteractionState.navigation);
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Builder(
                        builder: (context) {
                          final hasAgent = lineUp.currentAgent != null;
                          final hasAbility = lineUp.currentAbility != null;
                          final isDisabled = !hasAgent || !hasAbility;
                          final tooltipMessage = !hasAgent && !hasAbility
                              ? "Place an agent and ability to continue"
                              : !hasAgent
                                  ? "Place an agent to continue"
                                  : !hasAbility
                                      ? "Place an ability to continue"
                                      : "Finalize lineup details";

                          return ShadTooltip(
                            builder: (_) => Text(tooltipMessage),
                            child: ShadGestureDetector(
                              child: ShadButton(
                                trailing: const Icon(LucideIcons.arrowRight),
                                enabled: !isDisabled,
                                onPressed: () {
                                  showShadDialog(
                                    context: context,
                                    builder: (dialogContext) {
                                      return const CreateLineupDialog();
                                    },
                                  );
                                },
                                child: const Text("Next"),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
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
                .updateData(AgentData.forType(placedAgent.type)!);
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
