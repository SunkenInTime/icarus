import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/widgets/ability/rotatable_widget.dart';
import 'dart:math' as math;

class PlacedAbilityWidget extends StatefulWidget {
  final PlacedAbility ability;
  final Function(DraggableDetails details) onDragEnd;
  final int index;
  const PlacedAbilityWidget(
      {super.key,
      required this.ability,
      required this.onDragEnd,
      required this.index});

  @override
  State<PlacedAbilityWidget> createState() => _PlacedAbilityWidgetState();
}

class _PlacedAbilityWidgetState extends State<PlacedAbilityWidget> {
  Offset rotationOrigin = Offset.zero;
  GlobalKey globalKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;

    return Consumer(builder: (context, ref, child) {
      double rotation = ref.watch(abilityProvider)[widget.index].rotation;
      return Positioned(
        left: coordinateSystem.coordinateToScreen(widget.ability.position).dx,
        top: coordinateSystem.coordinateToScreen(widget.ability.position).dy,
        child: (widget.ability.data.abilityData is! SquareAbility)
            ? Draggable(
                feedback: widget.ability.data.abilityData.createWidget(),
                childWhenDragging: const SizedBox.shrink(),
                onDragEnd: widget.onDragEnd,
                child: widget.ability.data.abilityData.createWidget(),
              )
            : RotatableWidget(
                rotation: rotation,
                origin: widget.ability.data.abilityData.getAnchorPoint(),
                onPanStart: (details) {
                  final box = context.findRenderObject() as RenderBox;
                  final bottomCenter = widget.ability.data.abilityData
                      .getAnchorPoint()
                      .scale(coordinateSystem.scaleFactor,
                          coordinateSystem.scaleFactor);
                  // final bottomCenter =
                  //     Offset(box.size.width / 2, box.size.height);

                  rotationOrigin = box.localToGlobal(bottomCenter);
                },
                onPanUpdate: (details) {
                  if (rotationOrigin == Offset.zero) return;

                  final currentPosition = details.globalPosition;

                  // Calculate angles
                  final Offset currentPositionNormalized =
                      (currentPosition - rotationOrigin);

                  double currentAngle = math.atan2(currentPositionNormalized.dy,
                      currentPositionNormalized.dx);

                  // // Update rotation
                  final newRotation = (currentAngle) + (math.pi / 2);
                  ref
                      .read(abilityProvider.notifier)
                      .updateRotation(widget.index, newRotation);
                },
                onPanEnd: (details) {
                  setState(() {
                    rotationOrigin = Offset.zero;
                  });
                },
                child: Draggable(
                  feedback: ref
                      .watch(abilityProvider)[widget.index]
                      .data
                      .abilityData
                      .createWidget(rotation),
                  childWhenDragging: const SizedBox.shrink(),
                  onDragEnd: widget.onDragEnd,
                  // dragAnchorStrategy: pointDragAnchorStrategy,
                  child: ref
                      .watch(abilityProvider)[widget.index]
                      .data
                      .abilityData
                      .createWidget(rotation),
                ),
              ),
      );
    });
  }
}
