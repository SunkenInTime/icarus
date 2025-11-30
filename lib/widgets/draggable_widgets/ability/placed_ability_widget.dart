import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/rotatable_widget.dart';
import 'dart:math' as math;

import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';

class PlacedAbilityWidget extends ConsumerStatefulWidget {
  final PlacedAbility ability;
  final Function(DraggableDetails details) onDragEnd;
  final String id;
  final PlacedWidget data;
  final double rotation;
  final double length;
  const PlacedAbilityWidget({
    super.key,
    required this.ability,
    required this.onDragEnd,
    required this.id,
    required this.data,
    required this.rotation,
    required this.length,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _PlacedAbilityWidgetState();
}

class _PlacedAbilityWidgetState extends ConsumerState<PlacedAbilityWidget> {
  Offset rotationOrigin = Offset.zero;

  Offset lengthOrigin = Offset.zero;
  GlobalKey globalKey = GlobalKey();

  double? localRotation;
  double? localLength;
  bool isDragging = false;

  @override
  void initState() {
    super.initState();
    localRotation ??= widget.rotation;
    localLength ??= widget.length;
  }

  Offset rotateOffset(Offset point, Offset origin, double angle) {
    // Translate point to origin
    final dx = point.dx - origin.dx;
    final dy = point.dy - origin.dy;

    // Rotate around origin using rotation matrix
    final rotatedX = dx * math.cos(angle) - dy * math.sin(angle);
    final rotatedY = dx * math.sin(angle) + dy * math.cos(angle);

    // Translate back
    return Offset(
      rotatedX + origin.dx,
      rotatedY + origin.dy,
    );
  }

  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;

    final abilitySize = ref.watch(strategySettingsProvider).abilitySize;
    if (localRotation == null) {
      return const SizedBox.shrink();
    }

    final index =
        PlacedWidget.getIndexByID(widget.id, ref.watch(abilityProvider));
    final bool isAlly = ref.watch(abilityProvider)[index].isAlly;

    final mapScale = Maps.mapScale[ref.watch(mapProvider).currentMap] ?? 1;
    //Linking the local rotation with global rotation for things like undo redo
    if (ref.watch(abilityProvider)[index].rotation != localRotation! &&
        rotationOrigin == Offset.zero) {
      localRotation = ref.read(abilityProvider)[index].rotation;
    }

    if (ref.watch(abilityProvider)[index].length != localLength! &&
        lengthOrigin == Offset.zero) {
      localLength = ref.read(abilityProvider)[index].length;
    }

    if (index < 0) {
      return Draggable<PlacedWidget>(
        dragAnchorStrategy:
            ref.read(screenZoomProvider.notifier).zoomDragAnchorStrategy,
        data: widget.data,
        feedback: Opacity(
          opacity: Settings.feedbackOpacity,
          child: ZoomTransform(
              child: widget.ability.data.abilityData!
                  .createWidget(id: null, isAlly: isAlly, mapScale: mapScale)),
        ),
        childWhenDragging: const SizedBox.shrink(),
        onDragEnd: widget.onDragEnd,
        child: widget.ability.data.abilityData!
            .createWidget(id: widget.id, isAlly: isAlly, mapScale: mapScale),
      );
    }

    if (widget.ability.data.abilityData is SquareAbility ||
        widget.ability.data.abilityData is CenterSquareAbility ||
        widget.ability.data.abilityData is RotatableImageAbility ||
        widget.ability.data.abilityData is ResizableSquareAbility) {
      final isCenterSquare =
          widget.ability.data.abilityData is CenterSquareAbility;
      final double? buttonTop;
      if (isCenterSquare) {
        buttonTop = widget.ability.data.abilityData!
                .getAnchorPoint(mapScale: mapScale, abilitySize: abilitySize)
                .dy -
            abilitySize -
            30;
      } else if (widget.ability.data.abilityData is ResizableSquareAbility) {
        final resizeWidget =
            (widget.ability.data.abilityData! as ResizableSquareAbility);

        // final double anchorLength = coordinateSystem.scale(
        //   resizeWidget.height -
        //       (coordinateSystem.normalize(localLength ?? 0))
        //           .clamp(resizeWidget.minLength, resizeWidget.height),
        // );
        final double clampedLength = resizeWidget.height -
            ((localLength ?? 0))
                .clamp(resizeWidget.minLength, resizeWidget.height);

        final double anchorLength = (clampedLength * mapScale);

        // log("anchor length: ${anchorLength.toString()} local length: ${localLength.toString()}");
        buttonTop = anchorLength;
      } else {
        buttonTop = null;
      }
      return Positioned(
        left: coordinateSystem.coordinateToScreen(widget.ability.position).dx,
        top: coordinateSystem.coordinateToScreen(widget.ability.position).dy,
        child: RotatableWidget(
          buttonTop: buttonTop,
          rotation: localRotation!,
          isDragging: isDragging,
          origin: widget.ability.data.abilityData!
              .getAnchorPoint(mapScale: mapScale, abilitySize: abilitySize),
          onPanStart: (details) {
            log("Rotation Start");
            // ref.read(abilityProvider.notifier).updateRotationHistory(index);
            // ref.read(abilityProvider.notifier).updateLengthHistory(index);

            final box = context.findRenderObject() as RenderBox;
            final bottomCenter = widget.ability.data.abilityData!
                .getAnchorPoint(mapScale: mapScale, abilitySize: abilitySize)
                .scale(
                    coordinateSystem.scaleFactor, coordinateSystem.scaleFactor);

            rotationOrigin = box.localToGlobal(bottomCenter);
            if (widget.ability.data.abilityData is ResizableSquareAbility) {
              final resizeAbility =
                  (widget.ability.data.abilityData! as ResizableSquareAbility);
              lengthOrigin = box.localToGlobal(
                resizeAbility.getLengthAnchor(mapScale, abilitySize).scale(
                    coordinateSystem.scaleFactor, coordinateSystem.scaleFactor),
              );
            }
          },
          onPanUpdate: (details) {
            if (rotationOrigin == Offset.zero) return;

            final currentPosition = details.globalPosition;

            // Calculate angles
            final Offset currentPositionNormalized =
                (currentPosition - rotationOrigin);

            double currentAngle = math.atan2(
                currentPositionNormalized.dy, currentPositionNormalized.dx);

            // // Update rotation
            final newRotation = (currentAngle) + (math.pi / 2);

            setState(() {
              localRotation = newRotation;
            });
            if (widget.ability.data.abilityData is ResizableSquareAbility) {
              final Offset currentPosLength = (currentPosition -
                  rotateOffset(lengthOrigin, rotationOrigin, localRotation!));
              double currentLength =
                  coordinateSystem.normalize(currentPosLength.distance) /
                      mapScale /
                      ref.watch(screenZoomProvider);

              setState(() {
                localLength = currentLength;
              });
            }
          },
          onPanEnd: (details) {
            ref
                .read(abilityProvider.notifier)
                .updateRotation(index, localRotation!, localLength ?? 0);

            setState(() {
              rotationOrigin = Offset.zero;
              lengthOrigin = Offset.zero;
            });
          },
          child: Draggable<PlacedWidget>(
            data: widget.data,
            dragAnchorStrategy: (draggable, context, position) {
              final RenderBox renderObject =
                  context.findRenderObject()! as RenderBox;
              final anchorPoint = widget.ability.data.abilityData!
                  .getAnchorPoint(mapScale: mapScale, abilitySize: abilitySize)
                  .scale(coordinateSystem.scaleFactor,
                      coordinateSystem.scaleFactor);
              Offset rotatedPos = rotateOffset(
                  renderObject.globalToLocal(position),
                  anchorPoint,
                  localRotation!);

              return ref
                  .read(screenZoomProvider.notifier)
                  .zoomOffset(rotatedPos);
            },
            feedback: Opacity(
              opacity: Settings.feedbackOpacity,
              child: Transform.rotate(
                angle: localRotation!,
                alignment: Alignment.topLeft,
                origin: widget.ability.data.abilityData!
                    .getAnchorPoint(
                        mapScale: mapScale, abilitySize: abilitySize)
                    .scale(
                        coordinateSystem.scaleFactor *
                            ref.watch(screenZoomProvider),
                        coordinateSystem.scaleFactor *
                            ref.watch(screenZoomProvider)),
                child: ZoomTransform(
                  child: ref
                      .watch(abilityProvider)[index]
                      .data
                      .abilityData!
                      .createWidget(
                          id: widget.id,
                          isAlly: isAlly,
                          mapScale: mapScale,
                          rotation: localRotation!,
                          length: localLength!),
                ),
              ),
            ),
            childWhenDragging: const SizedBox.shrink(),
            onDragStarted: () {
              setState(() {
                isDragging = true;
              });
            },
            onDragEnd: (DraggableDetails details) {
              setState(() {
                isDragging = false;
              });
              widget.onDragEnd(details);
            },
            // dragAnchorStrategy: pointDragAnchorStrategy,
            child: ref
                .watch(abilityProvider)[index]
                .data
                .abilityData!
                .createWidget(
                    id: widget.id,
                    isAlly: isAlly,
                    mapScale: mapScale,
                    rotation: localRotation!,
                    length: localLength!),
          ),
        ),
      );
    }
    return Positioned(
      left: coordinateSystem.coordinateToScreen(widget.ability.position).dx,
      top: coordinateSystem.coordinateToScreen(widget.ability.position).dy,
      child: Draggable<PlacedWidget>(
        dragAnchorStrategy:
            ref.read(screenZoomProvider.notifier).zoomDragAnchorStrategy,
        data: widget.data,
        feedback: Opacity(
          opacity: Settings.feedbackOpacity,
          child: ZoomTransform(
              child: widget.ability.data.abilityData!
                  .createWidget(id: null, isAlly: isAlly, mapScale: mapScale)),
        ),
        childWhenDragging: const SizedBox.shrink(),
        onDragEnd: widget.onDragEnd,
        child: widget.ability.data.abilityData!
            .createWidget(id: widget.id, isAlly: isAlly, mapScale: mapScale),
      ),
    );
  }
}
