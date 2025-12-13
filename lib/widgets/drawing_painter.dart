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
import 'package:icarus/widgets/cursor_circle.dart';

final visualPositionProvider = StateProvider<Offset?>((ref) {
  return null;
});

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

  Offset? _visualMousePosition;
  @override
  Widget build(BuildContext context) {
    CoordinateSystem coordinateSystem = CoordinateSystem.instance;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // During screenshots we already rebuild paths explicitly; avoid racing with capture
      if (!coordinateSystem.isScreenshot &&
          _previousSize != coordinateSystem.effectiveSize) {
        ref.read(drawingProvider.notifier).rebuildAllPaths(coordinateSystem);
        _previousSize = coordinateSystem.effectiveSize;
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
          cursor: currentInteractionState == InteractionState.drawing
              ? ref.watch(penProvider).drawingCursor!
              : currentInteractionState == InteractionState.erasing
                  ? SystemMouseCursors.none
                  : SystemMouseCursors.basic,
          onEnter: (event) {
            if (currentInteractionState != InteractionState.erasing) return;
            // setState(() {
            //   _visualMousePosition = event.localPosition;
            // });
            ref.read(visualPositionProvider.notifier).state =
                event.localPosition;
          },
          onExit: (event) {
            if (currentInteractionState != InteractionState.erasing) return;

            // setState(() {
            //   _visualMousePosition = null;
            // });
            ref.read(visualPositionProvider.notifier).state = null;
          },
          onHover: (event) {
            if (currentInteractionState != InteractionState.erasing) return;

            // setState(() {
            //   _visualMousePosition = event.localPosition;
            // });
            ref.read(visualPositionProvider.notifier).state =
                event.localPosition;
          },
          child: GestureDetector(
            onPanStart: (details) {
              log("Pan start detected");
              final currentColor = ref.watch(penProvider).color;
              final hasArrow = ref.watch(penProvider).hasArrow;
              final isDotted = ref.watch(penProvider).isDotted;
              log(currentColor.toString());

              switch (currentInteractionState) {
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

                  // setState(() {
                  //   _visualMousePosition = details.localPosition;
                  // });
                  ref.read(visualPositionProvider.notifier).state =
                      details.localPosition;
                default:
              }
            },

            // },
            onPanUpdate: (details) {
              switch (currentInteractionState) {
                case InteractionState.drawing:
                  ref.read(drawingProvider.notifier).updateFreeDrawing(
                      details.localPosition, coordinateSystem);
                case InteractionState.erasing:
                  final normalizedPosition = CoordinateSystem.instance
                      .screenToCoordinate(details.localPosition);
                  ref
                      .read(drawingProvider.notifier)
                      .onErase(normalizedPosition);

                  // setState(() {
                  //   _visualMousePosition = details.localPosition;
                  // });
                  ref.read(visualPositionProvider.notifier).state =
                      details.localPosition;
                default:
              }
            },
            onPanEnd: (details) {
              switch (currentInteractionState) {
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
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: drawingPainter,
                  ),
                ),
                Consumer(
                  builder: (context, ref, child) {
                    if (currentInteractionState != InteractionState.erasing)
                      return const SizedBox.shrink();

                    final visualPosition = ref.watch(visualPositionProvider);

                    if (visualPosition == null) return const SizedBox.shrink();

                    return Stack(
                      children: [
                        Positioned(
                          left: visualPosition.dx -
                              (coordinateSystem
                                      .scale(Settings.erasingSize * 2) /
                                  2),
                          top: visualPosition.dy -
                              (coordinateSystem
                                      .scale(Settings.erasingSize * 2) /
                                  2),
                          child: IgnorePointer(
                            ignoring: true,
                            child: CursorCircle(
                              size: coordinateSystem
                                  .scale(Settings.erasingSize * 2),
                              ringThickness: 1,
                              gap: 1,
                              ringColor:
                                  Settings.tacticalVioletTheme.destructive,
                              fillColor: Settings
                                  .tacticalVioletTheme.destructive
                                  .withOpacity(0.5),
                            ),
                          ),
                        )
                      ],
                    );
                  },
                ),
              ],
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
        if (points.length < 2) continue;

        if (freeDrawing.isDotted) {
          final space = coordinateSystem.scale(10);
          DashPainter(span: space, step: space)
              .paint(canvas, freeDrawing.path, paint);
        } else {
          canvas.drawPath(freeDrawing.path, paint);
        }

        if (freeDrawing.hasArrow) {
          if (points.length < 2) continue;

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
    if (oldDelegate.updateCounter != updateCounter ||
        oldDelegate.coordinateSystem.isScreenshot) {
      // log("Repainting DrawingPainter");
      return true;
    } // Repaint when elements change
    return false;
  }
}
