// ignore_for_file: prefer_const_constructors, prefer_const_literals_to_create_immutables

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/ability_bar_provider.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/canvas_resize_provider.dart';
import 'package:icarus/providers/duplicate_drag_modifier_provider.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/team_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/draggable_widgets/agents/placed_circle_agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/agents/placed_view_cone_agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/image/placed_image_builder.dart';
import 'package:icarus/widgets/draggable_widgets/ability/placed_ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/text/placed_text_builder.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/placed_custom_circle_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/placed_custom_rectangle_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/utility_widget_builder.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/placed_view_cone_widget.dart';
import 'package:icarus/const/utilities.dart';
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
  PlacedAgent? _hoveredAgentAttachmentTarget() {
    final hoveredTarget = ref.read(hoveredDeleteTargetProvider);
    if (hoveredTarget == null || hoveredTarget.type != DeleteTargetType.agent) {
      return null;
    }

    for (final agent in ref.read(agentProvider)) {
      if (agent is PlacedAgent && agent.id == hoveredTarget.id) {
        return agent;
      }
    }
    return null;
  }

  void _convertToolbarConeToComposite({
    required PlacedAgent targetAgent,
    required VisionConeToolData toolData,
  }) {
    ref.read(actionProvider.notifier).performTransaction(
      groups: const [ActionGroup.agent],
      mutation: () {
        ref.read(agentProvider.notifier).convertPlainAgentToViewCone(
              id: targetAgent.id,
              presetType: toolData.type,
              rotation: 0,
              length:
                  UtilityData.getViewConePreset(toolData.type).defaultLength,
            );
      },
    );
  }

  void _convertToolbarCircleToComposite({
    required PlacedAgent targetAgent,
    required CustomShapeToolData toolData,
  }) {
    ref.read(actionProvider.notifier).performTransaction(
      groups: const [ActionGroup.agent],
      mutation: () {
        ref.read(agentProvider.notifier).convertPlainAgentToCircle(
              id: targetAgent.id,
              diameterMeters: toolData.diameterMeters,
              colorValue: toolData.colorValue,
              opacityPercent: toolData.opacityPercent,
            );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;
    final mapScale = Maps.mapScale[ref.watch(mapProvider).currentMap] ?? 1.0;

    final agentSize =
        coordinateSystem.scale(ref.watch(strategySettingsProvider).agentSize);
    final abilitySize = ref.watch(strategySettingsProvider).abilitySize;

    return LayoutBuilder(
      builder: (context, constraints) {
        final interactionState = ref.watch(interactionStateProvider);
        return DragTarget<DraggableData>(
          builder: (context, candidateData, rejectedData) {
            return RepaintBoundary(
              child: IgnorePointer(
                ignoring: interactionState == InteractionState.drawing ||
                    interactionState == InteractionState.erasing ||
                    interactionState == InteractionState.lineUpPlacing,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Align(
                    //   alignment: Alignment.topRight,
                    //   child: const DeleteArea(),
                    // ),
                    _CustomShapeUtilityList(
                      coordinateSystem: coordinateSystem,
                      mapScale: mapScale,
                    ),
                    _ViewConeUtilityList(
                      coordinateSystem: coordinateSystem,
                      agentSize: agentSize,
                    ),
                    _AbilityList(
                      coordinateSystem: coordinateSystem,
                      mapScale: mapScale,
                      abilitySize: abilitySize,
                    ),
                    _AgentList(coordinateSystem: coordinateSystem),
                    _TextList(
                      coordinateSystem: coordinateSystem,
                      agentSize: agentSize,
                    ),
                    _PlacedImageList(
                      coordinateSystem: coordinateSystem,
                      agentSize: agentSize,
                    ),
                    _UtilityList(
                      coordinateSystem: coordinateSystem,
                      agentSize: agentSize,
                      abilitySize: abilitySize,
                      mapScale: mapScale,
                    ),
                    const LineUpOverlay(),
                  ],
                ),
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
                isAlly: ref.read(teamProvider),
              );

              if (ref.read(interactionStateProvider) ==
                  InteractionState.lineUpPlacing) {
                ref.read(lineUpProvider.notifier).startNewGroup(placedAgent);
                return;
              }
              ref.read(agentProvider.notifier).addAgent(placedAgent);
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

              if (ref.read(interactionStateProvider) ==
                  InteractionState.lineUpPlacing) {
                ref
                    .read(lineUpProvider.notifier)
                    .setCurrentAbility(placedAbility);
                return;
              }

              ref.read(abilityProvider.notifier).addAbility(placedAbility);
            } else if (details.data is VisionConeToolData) {
              final visionConeData = details.data as VisionConeToolData;
              final targetAgent = _hoveredAgentAttachmentTarget();
              if (targetAgent != null) {
                _convertToolbarConeToComposite(
                  targetAgent: targetAgent,
                  toolData: visionConeData,
                );
              } else {
                ref.read(utilityProvider.notifier).addUtility(
                      PlacedUtility(
                        id: uuid.v4(),
                        type: visionConeData.type,
                        position: normalizedPosition,
                        angle: visionConeData.angle,
                      ),
                    );
              }
            } else if (details.data is SpikeToolData) {
              final spikeData = details.data as SpikeToolData;
              final placedUtility = PlacedUtility(
                id: uuid.v4(),
                type: spikeData.type,
                position: normalizedPosition,
              );
              ref.read(utilityProvider.notifier).addUtility(placedUtility);
            } else if (details.data is RoleIconToolData) {
              final roleIconData = details.data as RoleIconToolData;
              ref.read(utilityProvider.notifier).addUtility(
                    PlacedUtility(
                      id: uuid.v4(),
                      type: roleIconData.type,
                      position: normalizedPosition,
                      isAlly: ref.read(teamProvider),
                    ),
                  );
            } else if (details.data is CustomShapeToolData) {
              final customData = details.data as CustomShapeToolData;
              final targetAgent = _hoveredAgentAttachmentTarget();
              if (targetAgent != null &&
                  customData.type == UtilityType.customCircle) {
                _convertToolbarCircleToComposite(
                  targetAgent: targetAgent,
                  toolData: customData,
                );
              } else {
                ref.read(utilityProvider.notifier).addUtility(
                      customData.type == UtilityType.customCircle
                          ? PlacedUtility(
                              id: uuid.v4(),
                              type: customData.type,
                              position: normalizedPosition,
                              customDiameter: customData.diameterMeters,
                              customColorValue: customData.colorValue,
                              customOpacityPercent: customData.opacityPercent,
                            )
                          : PlacedUtility(
                              id: uuid.v4(),
                              type: customData.type,
                              position: normalizedPosition,
                              customWidth: customData.widthMeters,
                              customLength: customData.rectLengthMeters,
                              customColorValue: customData.colorValue,
                              customOpacityPercent: customData.opacityPercent,
                            ),
                    );
              }
            } else if (details.data is TextToolData) {
              final textData = details.data as TextToolData;
              final placedText = PlacedText(
                id: uuid.v4(),
                position: normalizedPosition,
                size: textData.width,
                fontSize: 16,
                sizeVersion: worldSizedMediaVersion,
                tagColorValue: textData.tagColorValue,
              );
              ref.read(textProvider.notifier).addText(placedText);
            }
          },
          onLeave: (data) {},
        );
      },
    );
  }
}

PlacedAgent? _hoveredPlainAgentTarget(WidgetRef ref) {
  final hoveredTarget = ref.read(hoveredDeleteTargetProvider);
  if (hoveredTarget == null || hoveredTarget.type != DeleteTargetType.agent) {
    return null;
  }

  for (final agent in ref.read(agentProvider)) {
    if (agent is PlacedAgent && agent.id == hoveredTarget.id) {
      return agent;
    }
  }
  return null;
}

bool _convertFreeUtilityToComposite({
  required WidgetRef ref,
  required PlacedUtility utility,
  required PlacedAgent targetAgent,
}) {
  if (UtilityData.isViewCone(utility.type)) {
    ref.read(actionProvider.notifier).performTransaction(
      groups: const [ActionGroup.agent, ActionGroup.utility],
      mutation: () {
        ref.read(utilityProvider.notifier).removeUtility(utility.id);
        ref.read(agentProvider.notifier).convertPlainAgentToViewCone(
              id: targetAgent.id,
              presetType: utility.type,
              rotation: utility.rotation,
              length: utility.length,
            );
      },
    );
    return true;
  }

  if (utility.type == UtilityType.customCircle &&
      utility.customDiameter != null &&
      utility.customColorValue != null &&
      utility.customOpacityPercent != null) {
    ref.read(actionProvider.notifier).performTransaction(
      groups: const [ActionGroup.agent, ActionGroup.utility],
      mutation: () {
        ref.read(utilityProvider.notifier).removeUtility(utility.id);
        ref.read(agentProvider.notifier).convertPlainAgentToCircle(
              id: targetAgent.id,
              diameterMeters: utility.customDiameter!,
              colorValue: utility.customColorValue!,
              opacityPercent: utility.customOpacityPercent!,
            );
      },
    );
    return true;
  }

  return false;
}

class _AbilityList extends ConsumerWidget {
  const _AbilityList({
    required this.coordinateSystem,
    required this.mapScale,
    required this.abilitySize,
  });

  final CoordinateSystem coordinateSystem;
  final double mapScale;
  final double abilitySize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final abilities = ref.watch(abilityProvider);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final ability in abilities)
          PlacedAbilityWidget(
            key: ValueKey(ability.id),
            rotation: ability.rotation,
            data: ability,
            ability: ability,
            id: ability.id,
            length: ability.length,
            onDragEnd: (details) {
              final renderBox = context.findRenderObject() as RenderBox;
              final localOffset = renderBox.globalToLocal(details.offset);
              final virtualOffset =
                  coordinateSystem.screenToCoordinate(localOffset);
              final safeArea = ability.data.abilityData!
                  .getAnchorPoint(mapScale: mapScale, abilitySize: abilitySize);

              if (coordinateSystem.isOutOfBounds(
                  virtualOffset.translate(safeArea.dx, safeArea.dy))) {
                ref
                    .read(abilityProvider.notifier)
                    .removeAbilityAsAction(ability.id);
                return;
              }

              ref
                  .read(abilityProvider.notifier)
                  .updatePosition(virtualOffset, ability.id);
            },
          ),
      ],
    );
  }
}

class _AgentList extends ConsumerStatefulWidget {
  const _AgentList({required this.coordinateSystem});

  final CoordinateSystem coordinateSystem;

  @override
  ConsumerState<_AgentList> createState() => _AgentListState();
}

class _AgentListState extends ConsumerState<_AgentList> {
  final Map<String, String> _pendingDuplicateDragBySource = {};

  @override
  Widget build(BuildContext context) {
    final agents = ref.watch(agentProvider);
    final zoomDragAnchorStrategy =
        ref.read(screenZoomProvider.notifier).zoomDragAnchorStrategy;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final agent in agents)
          switch (agent) {
            PlacedAgent() => Positioned(
                key: ValueKey(agent.id),
                left: widget.coordinateSystem
                    .coordinateToScreen(agent.position)
                    .dx,
                top: widget.coordinateSystem
                    .coordinateToScreen(agent.position)
                    .dy,
                child: Draggable<PlacedWidget>(
                  data: agent,
                  dragAnchorStrategy: zoomDragAnchorStrategy,
                  onDragStarted: () {
                    final shouldDuplicate =
                        ref.read(duplicateDragModifierProvider);
                    if (!shouldDuplicate) return;

                    final duplicatedId =
                        ref.read(agentProvider.notifier).duplicateAgentAt(
                              sourceId: agent.id,
                              position: agent.position,
                            );
                    if (duplicatedId != null) {
                      _pendingDuplicateDragBySource[agent.id] = duplicatedId;
                    }
                  },
                  feedback: Opacity(
                    opacity: Settings.feedbackOpacity,
                    child: ZoomTransform(
                      child: AgentWidget(
                        state: agent.state,
                        isAlly: agent.isAlly,
                        id: "",
                        agent: AgentData.agents[agent.type]!,
                      ),
                    ),
                  ),
                  childWhenDragging: const SizedBox.shrink(),
                  onDragEnd: (details) {
                    final renderBox = context.findRenderObject() as RenderBox;
                    final localOffset = renderBox.globalToLocal(details.offset);
                    final virtualOffset =
                        widget.coordinateSystem.screenToCoordinate(localOffset);

                    final duplicateId =
                        _pendingDuplicateDragBySource.remove(agent.id);
                    if (duplicateId != null) {
                      ref
                          .read(agentProvider.notifier)
                          .updatePosition(virtualOffset, duplicateId);
                      return;
                    }

                    ref
                        .read(agentProvider.notifier)
                        .updatePosition(virtualOffset, agent.id);
                  },
                  child: AgentWidget(
                    state: agent.state,
                    isAlly: agent.isAlly,
                    id: agent.id,
                    agent: AgentData.agents[agent.type]!,
                  ),
                ),
              ),
            PlacedViewConeAgent() => PlacedViewConeAgentWidget(
                key: ValueKey(agent.id),
                agent: agent,
                onDragEnd: (details, draggedId) {
                  final renderBox = context.findRenderObject() as RenderBox;
                  final screenZoom = ref.read(screenZoomProvider);
                  final agentSize =
                      ref.read(strategySettingsProvider).agentSize;
                  final compositeOffset =
                      viewConeAgentCompositeAgentOffsetScreen(
                    coordinateSystem: widget.coordinateSystem,
                    agentSize: agentSize,
                  );
                  final localOffset = renderBox.globalToLocal(
                    details.offset +
                        compositeOffset.scale(screenZoom, screenZoom),
                  );
                  final virtualOffset =
                      widget.coordinateSystem.screenToCoordinate(localOffset);
                  ref
                      .read(agentProvider.notifier)
                      .updatePosition(virtualOffset, draggedId);
                },
              ),
            PlacedCircleAgent() => PlacedCircleAgentWidget(
                key: ValueKey(agent.id),
                agent: agent,
                onDragEnd: (details, draggedId) {
                  final renderBox = context.findRenderObject() as RenderBox;
                  final screenZoom = ref.read(screenZoomProvider);
                  final agentSize =
                      ref.read(strategySettingsProvider).agentSize;
                  final mapScale =
                      Maps.mapScale[ref.read(mapProvider).currentMap] ?? 1.0;
                  final compositeOffset = circleAgentCompositeAgentOffsetScreen(
                    coordinateSystem: widget.coordinateSystem,
                    agentSize: agentSize,
                    mapScale: mapScale,
                  );
                  final localOffset = renderBox.globalToLocal(
                    details.offset +
                        compositeOffset.scale(screenZoom, screenZoom),
                  );
                  final virtualOffset =
                      widget.coordinateSystem.screenToCoordinate(localOffset);
                  ref
                      .read(agentProvider.notifier)
                      .updatePosition(virtualOffset, draggedId);
                },
              ),
          },
      ],
    );
  }
}

class _TextList extends ConsumerWidget {
  const _TextList({
    required this.coordinateSystem,
    required this.agentSize,
  });

  final CoordinateSystem coordinateSystem;
  final double agentSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final placedTexts = ref.watch(textProvider);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final placedText in placedTexts)
          Positioned(
            key: ValueKey(placedText.id),
            left: coordinateSystem.coordinateToScreen(placedText.position).dx,
            top: coordinateSystem.coordinateToScreen(placedText.position).dy,
            child: PlacedTextBuilder(
              size: placedText.size,
              placedText: placedText,
              onDragEnd: (details) {
                final renderBox = context.findRenderObject() as RenderBox;
                final localOffset = renderBox.globalToLocal(details.offset);
                final virtualOffset =
                    coordinateSystem.screenToCoordinate(localOffset);
                final safeArea = agentSize / 2;

                if (coordinateSystem.isOutOfBounds(
                    virtualOffset.translate(safeArea, safeArea))) {
                  ref
                      .read(textProvider.notifier)
                      .removeTextAsAction(placedText.id);
                  return;
                }

                ref
                    .read(textProvider.notifier)
                    .updatePosition(virtualOffset, placedText.id);
              },
            ),
          ),
      ],
    );
  }
}

class _PlacedImageList extends ConsumerWidget {
  const _PlacedImageList({
    required this.coordinateSystem,
    required this.agentSize,
  });

  final CoordinateSystem coordinateSystem;
  final double agentSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final images = ref.watch(placedImageProvider).images;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final placedImage in images)
          Positioned(
            key: ValueKey(placedImage.id),
            left: coordinateSystem.coordinateToScreen(placedImage.position).dx,
            top: coordinateSystem.coordinateToScreen(placedImage.position).dy,
            child: PlacedImageBuilder(
              placedImage: placedImage,
              scale: placedImage.scale,
              onDragEnd: (details) {
                final renderBox = context.findRenderObject() as RenderBox;
                final localOffset = renderBox.globalToLocal(details.offset);
                final virtualOffset =
                    coordinateSystem.screenToCoordinate(localOffset);
                final safeArea = agentSize / 2;

                if (coordinateSystem.isOutOfBounds(
                    virtualOffset.translate(safeArea, safeArea))) {
                  ref
                      .read(placedImageProvider.notifier)
                      .removeImageAsAction(placedImage.id);
                  return;
                }

                ref
                    .read(placedImageProvider.notifier)
                    .updatePosition(virtualOffset, placedImage.id);
              },
            ),
          ),
      ],
    );
  }
}

class _ViewConeUtilityList extends ConsumerWidget {
  const _ViewConeUtilityList({
    required this.coordinateSystem,
    required this.agentSize,
  });

  final CoordinateSystem coordinateSystem;
  final double agentSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final utilities =
        ref.watch(utilityProvider).where(PageLayering.isViewConeUtility);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final placedUtility in utilities)
          PlacedViewConeWidget(
            key: ValueKey(placedUtility.id),
            utility: placedUtility,
            id: placedUtility.id,
            rotation: placedUtility.rotation,
            length: placedUtility.length,
            onDragEnd: (details) {
              final renderBox = context.findRenderObject() as RenderBox;
              final localOffset = renderBox.globalToLocal(details.offset);
              final virtualOffset =
                  coordinateSystem.screenToCoordinate(localOffset);

              // if (coordinateSystem.isOutOfBounds(
              //     virtualOffset.translate(agentSize / 2, agentSize / 2))) {
              //   ref.read(utilityProvider.notifier).removeUtility(placedUtility.id);
              //   return;
              // }

              final targetAgent = _hoveredPlainAgentTarget(ref);
              if (targetAgent != null &&
                  _convertFreeUtilityToComposite(
                    ref: ref,
                    utility: placedUtility,
                    targetAgent: targetAgent,
                  )) {
                return;
              }

              ref.read(utilityProvider.notifier).updatePosition(
                    virtualOffset,
                    placedUtility.id,
                  );
            },
          ),
      ],
    );
  }
}

class _UtilityList extends ConsumerWidget {
  const _UtilityList({
    required this.coordinateSystem,
    required this.agentSize,
    required this.abilitySize,
    required this.mapScale,
  });

  final CoordinateSystem coordinateSystem;
  final double agentSize;
  final double abilitySize;
  final double mapScale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final utilities =
        ref.watch(utilityProvider).where(PageLayering.isTopUtility);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final placedUtility in utilities)
          Positioned(
            key: ValueKey(placedUtility.id),
            left:
                coordinateSystem.coordinateToScreen(placedUtility.position).dx,
            top: coordinateSystem.coordinateToScreen(placedUtility.position).dy,
            child: UtilityWidgetBuilder(
              rotation: placedUtility.rotation,
              length: placedUtility.length,
              utility: placedUtility,
              id: placedUtility.id,
              onDragEnd: (details) {
                final renderBox = context.findRenderObject() as RenderBox;
                final localOffset = renderBox.globalToLocal(details.offset);
                final virtualOffset =
                    coordinateSystem.screenToCoordinate(localOffset);

                final safeArea = UtilityData.utilityWidgets[placedUtility.type]!
                        .getAnchorPoint(
                      mapScale: mapScale,
                      agentSize: agentSize,
                      abilitySize: abilitySize,
                    ) /
                    2;

                if (coordinateSystem.isOutOfBounds(
                    virtualOffset.translate(safeArea.dx, safeArea.dy))) {
                  ref
                      .read(utilityProvider.notifier)
                      .removeUtilityAsAction(placedUtility.id);
                  return;
                }

                ref
                    .read(utilityProvider.notifier)
                    .updatePosition(virtualOffset, placedUtility.id);
              },
            ),
          ),
      ],
    );
  }
}

class _CustomShapeUtilityList extends ConsumerWidget {
  const _CustomShapeUtilityList({
    required this.coordinateSystem,
    required this.mapScale,
  });

  final CoordinateSystem coordinateSystem;
  final double mapScale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final customShapes =
        ref.watch(utilityProvider).where(PageLayering.isCustomShapeUtility);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final placedUtility in customShapes)
          Positioned(
            key: ValueKey('custom-shape-${placedUtility.id}'),
            left:
                coordinateSystem.coordinateToScreen(placedUtility.position).dx,
            top: coordinateSystem.coordinateToScreen(placedUtility.position).dy,
            child: placedUtility.type == UtilityType.customCircle
                ? PlacedCustomCircleWidget(
                    utility: placedUtility,
                    id: placedUtility.id,
                    onDragEnd: (details) {
                      final renderBox = context.findRenderObject() as RenderBox;
                      final localOffset =
                          renderBox.globalToLocal(details.offset);
                      final virtualOffset =
                          coordinateSystem.screenToCoordinate(localOffset);

                      final diameterMeters = placedUtility.customDiameter;
                      if (diameterMeters == null) {
                        ref
                            .read(utilityProvider.notifier)
                            .removeUtility(placedUtility.id);
                        return;
                      }

                      final safeArea = UtilityData
                          .utilityWidgets[placedUtility.type]!
                          .getAnchorPoint(
                        mapScale: mapScale,
                        diameterMeters: diameterMeters,
                      );

                      if (coordinateSystem.isOutOfBounds(
                          virtualOffset.translate(safeArea.dx, safeArea.dy))) {
                        ref
                            .read(utilityProvider.notifier)
                            .removeUtilityAsAction(placedUtility.id);
                        return;
                      }

                      final targetAgent = _hoveredPlainAgentTarget(ref);
                      if (targetAgent != null &&
                          _convertFreeUtilityToComposite(
                            ref: ref,
                            utility: placedUtility,
                            targetAgent: targetAgent,
                          )) {
                        return;
                      }

                      ref.read(utilityProvider.notifier).updatePosition(
                            virtualOffset,
                            placedUtility.id,
                          );
                    },
                  )
                : PlacedCustomRectangleWidget(
                    utility: placedUtility,
                    id: placedUtility.id,
                    onDragEnd: (details) {
                      final renderBox = context.findRenderObject() as RenderBox;
                      final localOffset =
                          renderBox.globalToLocal(details.offset);
                      final virtualOffset =
                          coordinateSystem.screenToCoordinate(localOffset);

                      final widthMeters = placedUtility.customWidth;
                      final lengthMeters = placedUtility.customLength;
                      if (widthMeters == null || lengthMeters == null) {
                        ref
                            .read(utilityProvider.notifier)
                            .removeUtility(placedUtility.id);
                        return;
                      }

                      final width = widthMeters *
                          AgentData.inGameMetersDiameter *
                          mapScale;
                      final length = lengthMeters *
                          AgentData.inGameMetersDiameter *
                          mapScale;
                      final safeArea = Offset(length / 2, width / 2);

                      if (coordinateSystem.isOutOfBounds(
                          virtualOffset.translate(safeArea.dx, safeArea.dy))) {
                        ref
                            .read(utilityProvider.notifier)
                            .removeUtilityAsAction(placedUtility.id);
                        return;
                      }

                      ref
                          .read(utilityProvider.notifier)
                          .updatePosition(virtualOffset, placedUtility.id);
                    },
                  ),
          ),
      ],
    );
  }
}

class LineUpOverlay extends StatelessWidget {
  const LineUpOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: const [
        Positioned.fill(
          child: LineUpLinePainter(),
        ),
        _LineUpAgents(),
        _LineUpAbilities(),
      ],
    );
  }
}

class _LineUpAgents extends ConsumerWidget {
  const _LineUpAgents();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(canvasResizeProvider);
    final groups = ref.watch(lineUpProvider).groups;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final group in groups) LineUpGroupAgentWidget(group: group),
      ],
    );
  }
}

class _LineUpAbilities extends ConsumerWidget {
  const _LineUpAbilities();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(canvasResizeProvider);
    final groups = ref.watch(lineUpProvider).groups;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final group in groups)
          for (final item in group.items)
            LineUpItemAbilityWidget(groupId: group.id, item: item),
      ],
    );
  }
}
