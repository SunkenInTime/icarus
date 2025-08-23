import 'dart:developer';
import 'dart:math' as math;

import 'package:dash_painter/dash_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/main.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/pen_provider.dart';

class InteractivePainter extends ConsumerStatefulWidget {
  const InteractivePainter({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _InteractivePainterState();
}

class _InteractivePainterState extends ConsumerState<InteractivePainter> {
  Size? _previousSize;

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    CoordinateSystem coordinateSystem = CoordinateSystem.instance;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_previousSize != coordinateSystem.playAreaSize) {
        ref.read(drawingProvider.notifier).rebuildAllPaths(coordinateSystem);
        _previousSize = coordinateSystem.playAreaSize;
      }
    });
    // Get the drawing data here in the widget
    DrawingState drawingState = ref.watch(drawingProvider);

    CustomPainter drawingPainter = DrawingPainter(
        updateCounter: drawingState.updateCounter,
        coordinateSystem: coordinateSystem,
        elements: drawingState.elements, // Pass the data directly
        drawingProvider: ref.read(drawingProvider.notifier),
        currentLine: drawingState.currentElement);

    final currentInteractionState = ref.watch(interactionStateProvider);

    bool isNavigating =
        ((currentInteractionState != InteractionState.drawing) &&
            (currentInteractionState != InteractionState.erasing));
    return IgnorePointer(
      ignoring: isNavigating,
      child: RepaintBoundary(
        child: MouseRegion(
          cursor:
              ref.watch(interactionStateProvider) == InteractionState.drawing
                  ? drawingCursor!
                  : erasingCursor!,
          child: GestureDetector(
            onPanStart: (details) {
              log("Pan start detected");
              final currentColor = ref.watch(penProvider).color;
              final hasArrow = ref.watch(penProvider).hasArrow;
              final isDotted = ref.watch(penProvider).isDotted;
              log(currentColor.toString());
              switch (currentInteractionState) {
                // case InteractionState.drawLine:
                //   Offset lineStart =
                //       coordinateSystem.screenToCoordinate(details.localPosition);
                //   ref.read(drawingProvider.notifier).startLine(lineStart);

                case InteractionState.drawing:
                  ref.read(drawingProvider.notifier).startFreeDrawing(
                        details.localPosition,
                        coordinateSystem,
                        currentColor,
                        isDotted,
                        hasArrow,
                      );

                case InteractionState.erasing:
                  final normalizedPosition = CoordinateSystem.instance
                      .screenToCoordinate(details.localPosition);
                  ref
                      .read(drawingProvider.notifier)
                      .onErase(normalizedPosition);
                default:
              }
            },
            // onTapDown: (details) {
            //   switch (currentInteractionState) {
            //     // case InteractionState.drawLine:
            //     //   Offset lineStart =
            //     //       coordinateSystem.screenToCoordinate(details.localPosition);
            //     //   ref.read(drawingProvider.notifier).startLine(lineStart);

            //     case InteractionState.drawing:
            //       ref
            //           .read(drawingProvider.notifier)
            //           .startSimpleTap(details.localPosition, coordinateSystem);

            //     case InteractionState.erasing:
            //       final normalizedPosition = CoordinateSystem.instance
            //           .screenToCoordinate(details.localPosition);
            //       ref.read(drawingProvider.notifier).onErase(normalizedPosition);
            //     default:
            //   }
            // },
            onPanUpdate: (details) {
              switch (currentInteractionState) {
                // case InteractionState.drawLine:
                //   Offset lineEnd =
                //       coordinateSystem.screenToCoordinate(details.localPosition);

                //   ref.read(drawingProvider.notifier).updateCurrentLine(lineEnd);
                case InteractionState.drawing:
                  ref.read(drawingProvider.notifier).updateFreeDrawing(
                      details.localPosition, coordinateSystem);
                case InteractionState.erasing:
                  final normalizedPosition = CoordinateSystem.instance
                      .screenToCoordinate(details.localPosition);
                  ref
                      .read(drawingProvider.notifier)
                      .onErase(normalizedPosition);
                default:
              }
            },
            onPanEnd: (details) {
              switch (currentInteractionState) {
                // case InteractionState.drawLine:
                //   Offset lineEnd =
                //       coordinateSystem.screenToCoordinate(details.localPosition);
                //   ref.read(drawingProvider.notifier).finishCurrentLine(lineEnd);
                case InteractionState.drawing:
                  ref.read(drawingProvider.notifier).finishFreeDrawing(
                      details.localPosition, coordinateSystem);
                case InteractionState.erasing:
                  final normalizedPosition = CoordinateSystem.instance
                      .screenToCoordinate(details.localPosition);
                  ref
                      .read(drawingProvider.notifier)
                      .onErase(normalizedPosition);
                default:
              }
            },
            child: CustomPaint(
              painter: drawingPainter,
            ),
          ),
        ),
      ),
    );
  }
}

class DrawingPainter extends CustomPainter {
  final CoordinateSystem coordinateSystem;
  final List<DrawingElement> elements; // Store the drawing elements
  final DrawingElement? currentLine;
  final int updateCounter;
  final DrawingProvider drawingProvider;

  DrawingPainter({
    required this.updateCounter,
    required this.currentLine,
    required this.coordinateSystem,
    required this.elements,
    required this.drawingProvider,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = coordinateSystem.scale(Settings.brushSize)
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true
      ..strokeCap = StrokeCap.round;

    // Helper function to draw an arrow
    void drawArrow(Canvas canvas, Paint paint, Offset from, Offset to) {
      const double arrowHeadSize = 8; // Size of the arrowhead
      const double arrowAngle = math.pi / 4; // 30 degrees arrow head angle

      // Calculate the direction angle from `from` to `to`
      final angle = math.atan2(to.dy - from.dy, to.dx - from.dx);

      // Calculate the points for the arrow head lines.
      final arrowPoint1 = Offset(
        to.dx - arrowHeadSize * math.cos(angle - arrowAngle),
        to.dy - arrowHeadSize * math.sin(angle - arrowAngle),
      );
      final arrowPoint2 = Offset(
        to.dx - arrowHeadSize * math.cos(angle + arrowAngle),
        to.dy - arrowHeadSize * math.sin(angle + arrowAngle),
      );

      // Create a path for the arrowhead
      final arrowPath = Path();
      arrowPath.moveTo(to.dx, to.dy);
      arrowPath.lineTo(arrowPoint1.dx, arrowPoint1.dy);
      arrowPath.moveTo(to.dx, to.dy);
      arrowPath.lineTo(arrowPoint2.dx, arrowPoint2.dy);

      // Draw the arrowhead lines
      canvas.drawPath(arrowPath, paint);
    }

    for (int i = 0; i < elements.length; i++) {
      paint.color = elements[i].color;
      if (elements[i] is Line) {
        Line line = elements[i] as Line;
        Offset screenStartOffset =
            coordinateSystem.coordinateToScreen(line.lineStart);

        Offset screenEndOffset =
            coordinateSystem.coordinateToScreen(line.lineEnd);

        canvas.drawLine(screenStartOffset, screenEndOffset, paint);
      } else if (elements[i] is FreeDrawing) {
        FreeDrawing freeDrawing = elements[i] as FreeDrawing;
        List<Offset> points = freeDrawing.listOfPoints;
        if (points.length < 2) return;

        if (freeDrawing.isDotted) {
          final space = coordinateSystem.scale(10);
          DashPainter(span: space, step: space)
              .paint(canvas, freeDrawing.path, paint);
        } else {
          canvas.drawPath(freeDrawing.path, paint);
        }

        if (freeDrawing.hasArrow) {
          if (points.length < 2) return;

          final from =
              coordinateSystem.coordinateToScreen(points[points.length - 2]);
          final to = coordinateSystem.coordinateToScreen(points.last);
          drawArrow(canvas, paint, from, to);
        }
      }
    }

    if (currentLine != null) {
      paint.color = currentLine!.color;
      if (currentLine is FreeDrawing) {
        final drawingElement = currentLine as FreeDrawing;

        if (drawingElement.isDotted) {
          final space = coordinateSystem.scale(10);

          DashPainter(span: space, step: space)
              .paint(canvas, drawingElement.path, paint);
        } else {
          canvas.drawPath(drawingElement.path, paint);
        }

        final points = drawingElement.listOfPoints;
        if (drawingElement.hasArrow) {
          if (points.length < 2) return;
          final from =
              coordinateSystem.coordinateToScreen(points[points.length - 2]);
          final to = coordinateSystem.coordinateToScreen(points.last);
          drawArrow(canvas, paint, from, to);
        }
      }
    }
  }

  @override
  bool shouldRepaint(DrawingPainter oldDelegate) {
    return oldDelegate.updateCounter !=
        updateCounter; // Repaint when elements change
  }
}
