import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/screenshot_provider.dart';

// ignore: must_be_immutable
class RotatableWidget extends ConsumerStatefulWidget {
  final Widget child;
  final double rotation;
  final Offset origin;
  final Function(DragUpdateDetails details) onPanUpdate;
  final Function(DragStartDetails details) onPanStart;

  final Function(DragEndDetails details) onPanEnd;
  final bool isDragging;
  final double? buttonLeft;
  final double? buttonTop;
  RotatableWidget({
    super.key,
    required this.child,
    required this.rotation,
    required this.onPanUpdate,
    required this.onPanStart,
    required this.onPanEnd,
    required this.origin,
    required this.isDragging,
    this.buttonLeft,
    this.buttonTop,
  });
  bool isHovered = false;

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _RotatableWidgetState();
}

class _RotatableWidgetState extends ConsumerState<RotatableWidget> {
  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;
    final rotationOrigin = widget.origin
        .scale(coordinateSystem.scaleFactor, coordinateSystem.scaleFactor);
    final isScreenshot = ref.watch(screenshotProvider);
    return Transform.rotate(
      angle: widget.rotation,
      alignment: Alignment.topLeft,
      origin: rotationOrigin,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          widget.child,
          if (!widget.isDragging && !isScreenshot)
            Positioned(
              left: coordinateSystem
                  .scale((widget.buttonLeft ?? widget.origin.dx - 7.5)),
              top: coordinateSystem.scale((widget.buttonTop ?? 0)),
              child: MouseRegion(
                onEnter: (event) {
                  setState(() {
                    widget.isHovered = true;
                  });
                },
                onExit: (event) {
                  setState(() {
                    widget.isHovered = false;
                  });
                },
                child: SizedBox(
                  width: coordinateSystem.scale(15),
                  height: coordinateSystem.scale(15),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: widget.onPanStart,
                    onPanUpdate: widget.onPanUpdate,
                    onPanEnd: widget.onPanEnd,
                    onTap: () {
                      log("I'm being hit");
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: widget.isHovered
                            ? Colors.white
                            : Colors.white.withAlpha(200),
                        shape: BoxShape.circle,
                      ),
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
// }
// class RotatableWidget extends StatefulWidget {
//   final Widget child;
//   final double rotation;
//   final Offset origin;
//   final Function(DragUpdateDetails details) onPanUpdate;
//   final Function(DragStartDetails details) onPanStart;

//   final Function(DragEndDetails details) onPanEnd;
//   final bool isDragging;
//   final double? buttonLeft;
//   final double? buttonTop;
//   RotatableWidget({
//     super.key,
//     required this.child,
//     required this.rotation,
//     required this.onPanUpdate,
//     required this.onPanStart,
//     required this.onPanEnd,
//     required this.origin,
//     required this.isDragging,
//     this.buttonLeft,
//     this.buttonTop,
//   });
//   bool isHovered = false;

//   @override
//   State<RotatableWidget> createState() => _RotatableWidgetState();
// }

// class _RotatableWidgetState extends State<RotatableWidget> {
//   @override
//   Widget build(BuildContext context) {

//   }
// }
