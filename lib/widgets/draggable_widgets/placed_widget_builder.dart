import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/team_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/placed_image_builder.dart';
import 'package:icarus/widgets/delete_area.dart';
import 'package:icarus/widgets/draggable_widgets/ability/placed_ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/text/placed_text_builder.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/utility_widget_builder.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';
import 'package:icarus/widgets/line_up_line_painter.dart';
import 'package:icarus/widgets/line_up_widget.dart';
import 'package:uuid/uuid.dart';

class PlacedWidgetBuilder extends ConsumerStatefulWidget {
  const PlacedWidgetBuilder({super.key, this.isScreenshot = false});
  final bool isScreenshot;
  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _PlacedWidgetBuilderState();
}

class _PlacedWidgetBuilderState extends ConsumerState<PlacedWidgetBuilder> {
  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;
    final mapScale = Maps.mapScale[ref.watch(mapProvider).currentMap];

    final agentSize = ref.watch(strategySettingsProvider).agentSize;
    final abilitySize = ref.watch(strategySettingsProvider).abilitySize;

    return LayoutBuilder(
      builder: (context, constraints) {
        final interactionState = ref.watch(interactionStateProvider);
        log(ref.watch(mapProvider).isAttack.toString());
        return DragTarget<DraggableData>(
          builder: (context, candidateData, rejectedData) {
            return IgnorePointer(
              ignoring: interactionState == InteractionState.drawing ||
                  interactionState == InteractionState.erasing,
              child: Stack(
                children: [
                  const Align(
                    alignment: Alignment.topRight,
                    child: DeleteArea(),
                  ),
                  for (PlacedAbility ability in ref.watch(abilityProvider))
                    PlacedAbilityWidget(
                      rotation: ability.rotation,
                      data: ability,
                      ability: ability,
                      id: ability.id,
                      length: ability.length,
                      onDragEnd: (details) {
                        RenderBox renderBox =
                            context.findRenderObject() as RenderBox;
                        Offset localOffset =
                            renderBox.globalToLocal(details.offset);
                        // Updating info

                        Offset virtualOffset =
                            coordinateSystem.screenToCoordinate(localOffset);
                        Offset safeArea = ability.data.abilityData!
                            .getAnchorPoint(
                                mapScale: mapScale, abilitySize: abilitySize);

                        if (coordinateSystem.isOutOfBounds(virtualOffset
                            .translate(safeArea.dx, safeArea.dy))) {
                          ref
                              .read(abilityProvider.notifier)
                              .removeAbility(ability.id);
                          return;
                        }

                        log(renderBox.size.toString());

                        ref.read(abilityProvider.notifier).updatePosition(
                            coordinateSystem.screenToCoordinate(localOffset),
                            ability.id);
                      },
                    ),
                  for (PlacedAgent agent in ref.watch(agentProvider))
                    Positioned(
                      left: coordinateSystem
                          .coordinateToScreen(agent.position)
                          .dx,
                      top: coordinateSystem
                          .coordinateToScreen(agent.position)
                          .dy,
                      child: Draggable<PlacedWidget>(
                        data: agent,
                        dragAnchorStrategy: ref
                            .read(screenZoomProvider.notifier)
                            .zoomDragAnchorStrategy,
                        feedback: Opacity(
                          opacity: Settings.feedbackOpacity,
                          child: ZoomTransform(
                            child: AgentWidget(
                              isAlly: agent.isAlly,
                              id: "",
                              agent: AgentData.agents[agent.type]!,
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
                              .read(agentProvider.notifier)
                              .updatePosition(virtualOffset, agent.id);
                        },
                        child: RepaintBoundary(
                          child: AgentWidget(
                            isAlly: agent.isAlly,
                            id: agent.id,
                            agent: AgentData.agents[agent.type]!,
                          ),
                        ),
                      ),
                    ),
                  for (PlacedText placedText in ref.watch(textProvider))
                    Positioned(
                      left: coordinateSystem
                          .coordinateToScreen(placedText.position)
                          .dx,
                      top: coordinateSystem
                          .coordinateToScreen(placedText.position)
                          .dy,
                      child: PlacedTextBuilder(
                        size: placedText.size,
                        placedText: placedText,
                        onDragEnd: (details) {
                          RenderBox renderBox =
                              context.findRenderObject() as RenderBox;
                          Offset localOffset =
                              renderBox.globalToLocal(details.offset);

                          //Basically makes sure that if more than half is of the screen it gets deleted
                          Offset virtualOffset =
                              coordinateSystem.screenToCoordinate(localOffset);
                          double safeArea = agentSize / 2;

                          if (coordinateSystem.isOutOfBounds(
                              virtualOffset.translate(safeArea, safeArea))) {
                            ref
                                .read(textProvider.notifier)
                                .removeText(placedText.id);

                            return;
                          }

                          ref
                              .read(textProvider.notifier)
                              .updatePosition(virtualOffset, placedText.id);
                        },
                      ),
                    ),
                  for (PlacedImage placedImage
                      in ref.watch(placedImageProvider).images)
                    Positioned(
                        left: coordinateSystem
                            .coordinateToScreen(placedImage.position)
                            .dx,
                        top: coordinateSystem
                            .coordinateToScreen(placedImage.position)
                            .dy,
                        child: PlacedImageBuilder(
                          placedImage: placedImage,
                          scale: placedImage.scale,
                          onDragEnd: (details) {
                            RenderBox renderBox =
                                context.findRenderObject() as RenderBox;
                            Offset localOffset =
                                renderBox.globalToLocal(details.offset);

                            //Basically makes sure that if more than half is of the screen it gets deleted
                            Offset virtualOffset = coordinateSystem
                                .screenToCoordinate(localOffset);
                            double safeArea = agentSize / 2;

                            if (coordinateSystem.isOutOfBounds(
                                virtualOffset.translate(safeArea, safeArea))) {
                              ref
                                  .read(placedImageProvider.notifier)
                                  .removeImage(placedImage.id);

                              return;
                            }

                            ref
                                .read(placedImageProvider.notifier)
                                .updatePosition(virtualOffset, placedImage.id);
                          },
                        )),
                  for (PlacedUtility placedUtility
                      in ref.watch(utilityProvider))
                    Positioned(
                      left: coordinateSystem
                          .coordinateToScreen(placedUtility.position)
                          .dx,
                      top: coordinateSystem
                          .coordinateToScreen(placedUtility.position)
                          .dy,
                      child: UtilityWidgetBuilder(
                        rotation: placedUtility.rotation,
                        length: placedUtility.length,
                        utility: placedUtility,
                        id: placedUtility.id,
                        onDragEnd: (details) {
                          RenderBox renderBox =
                              context.findRenderObject() as RenderBox;
                          Offset localOffset =
                              renderBox.globalToLocal(details.offset);

                          //Basically makes sure that if more than half is of the screen it gets deleted
                          Offset virtualOffset =
                              coordinateSystem.screenToCoordinate(localOffset);
                          double safeArea = agentSize / 2;

                          if (coordinateSystem.isOutOfBounds(
                              virtualOffset.translate(safeArea, safeArea))) {
                            ref
                                .read(utilityProvider.notifier)
                                .removeUtility(placedUtility.id);

                            return;
                          }

                          ref
                              .read(utilityProvider.notifier)
                              .updatePosition(virtualOffset, placedUtility.id);
                        },
                      ),
                    ),
                  const Positioned.fill(
                    child: LineUpLinePainter(),
                  ),
                  Positioned.fill(
                    child: Stack(
                      children: [
                        for (final lineUp in ref.watch(lineUpProvider).lineUps)
                          LineUpWidget(lineUp: lineUp)
                      ],
                    ),
                  ),
                ],
              ),
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
                  isAlly: ref.read(teamProvider));

              ref.read(agentProvider.notifier).addAgent(placedAgent);
            } else if (details.data is AbilityInfo) {
              PlacedAbility placedAbility = PlacedAbility(
                id: uuid.v4(),
                data: details.data as AbilityInfo,
                position: normalizedPosition,
                isAlly: ref.read(teamProvider),
              );

              ref.read(abilityProvider.notifier).addAbility(placedAbility);
            }
          },
          onLeave: (data) {
            log("I have left");
          },
        );
      },
    );
  }
}
