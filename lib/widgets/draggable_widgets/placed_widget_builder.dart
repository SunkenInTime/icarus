// ignore_for_file: prefer_const_constructors, prefer_const_literals_to_create_immutables

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
import 'package:icarus/widgets/draggable_widgets/image/placed_image_builder.dart';
import 'package:icarus/widgets/draggable_widgets/ability/placed_ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/text/placed_text_builder.dart';
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
        log(ref.watch(mapProvider).isAttack.toString());
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
                    const Align(
                      alignment: Alignment.topRight,
                      child: DeleteArea(),
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
                    ),
                    const Positioned.fill(
                      child: LineUpLinePainter(),
                    ),
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        _LineUpAgents(),
                        _LineUpAbilities(),
                      ],
                    ),
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
                ref.read(lineUpProvider.notifier).setAgent(placedAgent);
                return;
              }
              ref.read(agentProvider.notifier).addAgent(placedAgent);
            } else if (details.data is AbilityInfo) {
              PlacedAbility placedAbility = PlacedAbility(
                id: uuid.v4(),
                data: details.data as AbilityInfo,
                position: normalizedPosition,
                isAlly: ref.read(teamProvider),
              );

              if (ref.read(interactionStateProvider) ==
                  InteractionState.lineUpPlacing) {
                ref.read(lineUpProvider.notifier).setAbility(placedAbility);
                return;
              }

              ref.read(abilityProvider.notifier).addAbility(placedAbility);
            } else if (details.data is VisionConeToolData) {
              final visionConeData = details.data as VisionConeToolData;
              final placedUtility = PlacedUtility(
                id: uuid.v4(),
                type: visionConeData.type,
                position: normalizedPosition,
                angle: visionConeData.angle,
              );
              ref.read(utilityProvider.notifier).addUtility(placedUtility);
            } else if (details.data is SpikeToolData) {
              final spikeData = details.data as SpikeToolData;
              final placedUtility = PlacedUtility(
                id: uuid.v4(),
                type: spikeData.type,
                position: normalizedPosition,
              );
              ref.read(utilityProvider.notifier).addUtility(placedUtility);
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
                ref.read(abilityProvider.notifier).removeAbility(ability.id);
                return;
              }

              log(renderBox.size.toString());

              ref
                  .read(abilityProvider.notifier)
                  .updatePosition(virtualOffset, ability.id);
            },
          ),
      ],
    );
  }
}

class _AgentList extends ConsumerWidget {
  const _AgentList({required this.coordinateSystem});

  final CoordinateSystem coordinateSystem;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agents = ref.watch(agentProvider);
    final zoomDragAnchorStrategy =
        ref.read(screenZoomProvider.notifier).zoomDragAnchorStrategy;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final agent in agents)
          Positioned(
            key: ValueKey(agent.id),
            left: coordinateSystem.coordinateToScreen(agent.position).dx,
            top: coordinateSystem.coordinateToScreen(agent.position).dy,
            child: Draggable<PlacedWidget>(
              data: agent,
              dragAnchorStrategy: zoomDragAnchorStrategy,
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
                    coordinateSystem.screenToCoordinate(localOffset);

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
                  ref.read(textProvider.notifier).removeText(placedText.id);
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
                      .removeImage(placedImage.id);
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
    final utilities = ref
        .watch(utilityProvider)
        .where((utility) => UtilityData.isViewCone(utility.type));

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

              ref
                  .read(utilityProvider.notifier)
                  .updatePosition(virtualOffset, placedUtility.id);
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
  });

  final CoordinateSystem coordinateSystem;
  final double agentSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final utilities = ref
        .watch(utilityProvider)
        .where((utility) => !UtilityData.isViewCone(utility.type));

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
                        .getAnchorPoint() /
                    2;

                if (coordinateSystem.isOutOfBounds(virtualOffset.translate(
                    safeArea.dx / 2, safeArea.dy / 2))) {
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
      ],
    );
  }
}

class _LineUpAgents extends ConsumerWidget {
  const _LineUpAgents();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lineUps = ref.watch(lineUpProvider).lineUps;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final lineUp in lineUps) LineUpAgentWidget(lineUp: lineUp),
      ],
    );
  }
}

class _LineUpAbilities extends ConsumerWidget {
  const _LineUpAbilities();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lineUps = ref.watch(lineUpProvider).lineUps;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final lineUp in lineUps) LineUpAbilityWidget(lineUp: lineUp),
      ],
    );
  }
}
