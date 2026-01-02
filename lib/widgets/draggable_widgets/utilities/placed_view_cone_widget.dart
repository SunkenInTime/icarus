import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/rotatable_widget.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';

class PlacedViewConeWidget extends ConsumerStatefulWidget {
  final PlacedUtility utility;
  final Function(DraggableDetails details) onDragEnd;
  final String id;
  final double rotation;
  final double length;

  const PlacedViewConeWidget({
    super.key,
    required this.utility,
    required this.onDragEnd,
    required this.id,
    required this.rotation,
    required this.length,
  });

  @override
  ConsumerState<PlacedViewConeWidget> createState() =>
      _PlacedViewConeWidgetState();
}

class _PlacedViewConeWidgetState extends ConsumerState<PlacedViewConeWidget> {
  Offset rotationOrigin = Offset.zero;
  double? localRotation;
  double? localLength;
  bool isDragging = false;

  @override
  void initState() {
    super.initState();
    localRotation = widget.rotation;
    localLength = widget.length > 0 ? widget.length : 50;
  }

  /// Rotate a point around an origin by a given angle
  Offset rotateOffset(Offset point, Offset origin, double angle) {
    final dx = point.dx - origin.dx;
    final dy = point.dy - origin.dy;

    final rotatedX = dx * math.cos(angle) - dy * math.sin(angle);
    final rotatedY = dx * math.sin(angle) + dy * math.cos(angle);

    return Offset(
      rotatedX + origin.dx,
      rotatedY + origin.dy,
    );
  }

  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;

    if (localRotation == null) {
      return const SizedBox.shrink();
    }

    final index =
        PlacedWidget.getIndexByID(widget.id, ref.watch(utilityProvider));

    if (index < 0) {
      return const SizedBox.shrink();
    }

    final utilityRef = ref.watch(utilityProvider)[index];

    // Sync local state with provider state (for undo/redo)
    // Same pattern as PlacedAbilityWidget
    if (utilityRef.rotation != localRotation! &&
        rotationOrigin == Offset.zero) {
      localRotation = utilityRef.rotation;
    }
    if (utilityRef.length != localLength! && rotationOrigin == Offset.zero) {
      localLength = utilityRef.length > 0 ? utilityRef.length : 50;
    }

    // Get the view cone utility to access its methods
    final viewConeUtility =
        UtilityData.utilityWidgets[widget.utility.type] as ViewConeUtility;

    // Calculate anchor point - bottom center of the cone, based on current length
    // This is exactly like how abilities calculate their anchor points
    final anchorPoint = viewConeUtility.getAnchorPoint();

    return Positioned(
      left: coordinateSystem.coordinateToScreen(widget.utility.position).dx,
      top: coordinateSystem.coordinateToScreen(widget.utility.position).dy,
      child: RotatableWidget(
        rotation: localRotation!,
        isDragging: isDragging,
        origin: anchorPoint,
        // Position the rotation handle at the top (where the cone extends to)
        buttonTop: anchorPoint.dy - localLength! - 7.5,
        buttonLeft: anchorPoint.dx - 7.5,
        onPanStart: (details) {
          // Save rotation history for undo/redo
          ref.read(utilityProvider.notifier).updateRotationHistory(index);

          // Get the global position of the anchor point
          final box = context.findRenderObject() as RenderBox;
          final scaledAnchor = anchorPoint.scale(
            coordinateSystem.scaleFactor,
            coordinateSystem.scaleFactor,
          );
          rotationOrigin = box.localToGlobal(scaledAnchor);
        },
        onPanUpdate: (details) {
          if (rotationOrigin == Offset.zero) return;

          final currentPosition = details.globalPosition;
          final currentPositionNormalized = currentPosition - rotationOrigin;

          // Calculate rotation angle - same as PlacedAbilityWidget
          double currentAngle = math.atan2(
            currentPositionNormalized.dy,
            currentPositionNormalized.dx,
          );
          final newRotation = currentAngle + (math.pi / 2);

          // Calculate new length from distance
          double newLength = coordinateSystem.normalize(
                currentPositionNormalized.distance,
              ) /
              ref.watch(screenZoomProvider);

          // Clamp length to valid range
          newLength = newLength.clamp(
            ViewConeUtility.minLength,
            ViewConeUtility.maxLength,
          );

          setState(() {
            localRotation = newRotation;
            localLength = newLength;
          });
        },
        onPanEnd: (details) {
          ref.read(utilityProvider.notifier).updateRotation(
                index,
                localRotation!,
                localLength ?? 50,
              );

          setState(() {
            rotationOrigin = Offset.zero;
          });
        },
        child: Draggable<PlacedUtility>(
          data: widget.utility,
          // Custom drag anchor strategy - same pattern as PlacedAbilityWidget
          dragAnchorStrategy: (draggable, context, position) {
            final RenderBox renderObject =
                context.findRenderObject()! as RenderBox;
            final scaledAnchor = anchorPoint.scale(
              coordinateSystem.scaleFactor,
              coordinateSystem.scaleFactor,
            );

            // Rotate the local position around the anchor point
            Offset rotatedPos = rotateOffset(
              renderObject.globalToLocal(position),
              scaledAnchor,
              localRotation!,
            );

            return ref.read(screenZoomProvider.notifier).zoomOffset(rotatedPos);
          },
          feedback: Opacity(
            opacity: Settings.feedbackOpacity,
            child: Transform.rotate(
              angle: localRotation!,
              alignment: Alignment.topLeft,
              origin: anchorPoint.scale(
                coordinateSystem.scaleFactor * ref.watch(screenZoomProvider),
                coordinateSystem.scaleFactor * ref.watch(screenZoomProvider),
              ),
              child: ZoomTransform(
                child: UtilityData.utilityWidgets[widget.utility.type]!
                    .createWidget(
                        id: null, rotation: localRotation, length: localLength),
              ),
            ),
          ),
          childWhenDragging: const SizedBox.shrink(),
          onDragStarted: () {
            setState(() {
              isDragging = true;
            });
          },
          onDragEnd: (details) {
            setState(() {
              isDragging = false;
            });
            widget.onDragEnd(details);
          },
          child: UtilityData.utilityWidgets[widget.utility.type]!.createWidget(
              id: widget.id, rotation: localRotation, length: localLength),
        ),
      ),
    );
  }
}
