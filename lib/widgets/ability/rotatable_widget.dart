import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:icarus/const/coordinate_system.dart';

class RotatableWidget extends StatelessWidget {
  final Widget child;
  final double rotation;
  final Offset origin;
  final Function(DragUpdateDetails details) onPanUpdate;
  final Function(DragStartDetails details) onPanStart;

  final Function(DragEndDetails details) onPanEnd;

  const RotatableWidget({
    super.key,
    required this.child,
    required this.rotation,
    required this.onPanUpdate,
    required this.onPanStart,
    required this.onPanEnd,
    required this.origin,
  });

  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;
    final rotationOrigin = origin.scale(
        coordinateSystem.scaleFactor, coordinateSystem.scaleFactor);
    return Transform.rotate(
      angle: rotation,
      alignment: Alignment.topLeft,
      origin: rotationOrigin,
      child: Stack(
        children: [
          child,

          //Circle
          Positioned.fill(
            child: Align(
              alignment: Alignment.topCenter,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: onPanStart,
                onPanUpdate: onPanUpdate,
                onPanEnd: onPanEnd,
                onTap: () {
                  log("I'm being hit");
                },
                child: Container(
                  width: coordinateSystem.scale(15),
                  height: coordinateSystem.scale(15),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
