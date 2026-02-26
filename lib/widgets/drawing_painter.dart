import 'dart:developer';
import 'dart:math' as math;

import 'package:dash_painter/dash_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/traversal_speed.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/pen_provider.dart';
import 'package:icarus/widgets/cursor_circle.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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
    final penState = ref.watch(penProvider);
    final mapScale = ref.watch(mapProvider.notifier).mapScale;
    final isAttack = ref.watch(mapProvider.select((state) => state.isAttack));

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
              ? penState.drawingCursor!
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
              log(penState.color.toString());

              switch (currentInteractionState) {
                case InteractionState.drawing:
                  if (penState.penMode == PenMode.square) {
                    ref.read(drawingProvider.notifier).startRectangle(
                          details.localPosition,
                          coordinateSystem,
                          penState.color,
                          penState.isDotted,
                        );
                  } else {
                    ref.read(drawingProvider.notifier).startFreeDrawing(
                          details.localPosition,
                          coordinateSystem,
                          penState.color,
                          penState.isDotted,
                          penState.hasArrow,
                          penState.traversalTimeEnabled,
                          penState.activeTraversalSpeedProfile,
                        );
                  }

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
                  if (penState.penMode == PenMode.square) {
                    ref.read(drawingProvider.notifier).updateRectangle(
                          details.localPosition,
                          coordinateSystem,
                        );
                  } else {
                    ref.read(drawingProvider.notifier).updateFreeDrawing(
                        details.localPosition, coordinateSystem);
                  }
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
                  if (penState.penMode == PenMode.square) {
                    ref
                        .read(drawingProvider.notifier)
                        .finishRectangle(null, coordinateSystem);
                  } else {
                    ref
                        .read(drawingProvider.notifier)
                        .finishFreeDrawing(null, coordinateSystem);
                  }
                case InteractionState.erasing:
                  ref.read(visualPositionProvider.notifier).state = null;
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
                Positioned.fill(
                  child: IgnorePointer(
                    child: _TraversalTimeOverlay(
                      coordinateSystem: coordinateSystem,
                      mapScale: mapScale,
                      isAttack: isAttack,
                      elements: drawingState.elements,
                      currentLine: drawingState.currentElement,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TraversalTimeOverlay extends StatelessWidget {
  const _TraversalTimeOverlay({
    required this.coordinateSystem,
    required this.mapScale,
    required this.isAttack,
    required this.elements,
    required this.currentLine,
  });

  final CoordinateSystem coordinateSystem;
  final double mapScale;
  final bool isAttack;
  final List<DrawingElement> elements;
  final DrawingElement? currentLine;

  @override
  Widget build(BuildContext context) {
    final cards = <Widget>[
      for (final element in elements.whereType<FreeDrawing>())
        if (element.showTraversalTime)
          _buildTraversalCard(
            drawing: element,
            coordinateSystem: coordinateSystem,
            mapScale: mapScale,
            isAttack: isAttack,
          ),
      if (currentLine is FreeDrawing &&
          (currentLine as FreeDrawing).showTraversalTime)
        _buildTraversalCard(
          drawing: currentLine as FreeDrawing,
          coordinateSystem: coordinateSystem,
          mapScale: mapScale,
          isAttack: isAttack,
        ),
    ];

    if (cards.isEmpty) return const SizedBox.shrink();

    return Stack(
      clipBehavior: Clip.none,
      children: cards,
    );
  }
}

Widget _buildTraversalCard({
  required FreeDrawing drawing,
  required CoordinateSystem coordinateSystem,
  required double mapScale,
  required bool isAttack,
}) {
  if (drawing.listOfPoints.isEmpty) return const SizedBox.shrink();

  final unitsPerMeter = AgentData.inGameMeters * mapScale;
  if (unitsPerMeter <= 0) return const SizedBox.shrink();

  const cardWidthMeters = 8.0;
  const cardHeightMeters = 3.5;
  const xOffsetMeters = 0.8;
  const yOffsetMeters = 0.8;

  final cardWidthScreen =
      coordinateSystem.scale(cardWidthMeters * unitsPerMeter);
  final cardHeightScreen =
      coordinateSystem.scale(cardHeightMeters * unitsPerMeter);
  final anchor = drawing.listOfPoints.last.translate(
    xOffsetMeters * unitsPerMeter,
    -yOffsetMeters * unitsPerMeter,
  );
  final anchorScreen = coordinateSystem.coordinateToScreen(anchor);

  final timeSeconds = _calculateTraversalTime(
    drawing: drawing,
    unitsPerMeter: unitsPerMeter,
  );
  final label = "${timeSeconds.toStringAsFixed(2)}s";
  final iconSize = coordinateSystem.scale(10).clamp(10.0, 20.0).toDouble();
  final leadingIcon = _buildTraversalModeIcon(
    profile: drawing.traversalSpeedProfile,
    size: iconSize,
  );

  return Positioned(
    left: anchorScreen.dx,
    top: anchorScreen.dy,
    child: Container(
      width: cardWidthScreen,
      height: cardHeightScreen,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(coordinateSystem.scale(4)),
        border: Border.all(
          color: Settings.tacticalVioletTheme.border,
          width: 1,
        ),
      ),
      // Defensive-side drawings are rotated, so flip card text diagonally too.
      child: Transform(
        alignment: Alignment.center,
        transform: !isAttack
            ? Matrix4.diagonal3Values(-1.0, -1.0, 1.0)
            : Matrix4.identity(),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                leadingIcon,
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: coordinateSystem.scale(10),
                    color: Settings.tacticalVioletTheme.foreground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _buildTraversalModeIcon({
  required TraversalSpeedProfile profile,
  required double size,
}) {
  switch (profile) {
    case TraversalSpeedProfile.running:
      return Icon(
        LucideIcons.chevronsUp,
        size: size,
        color: Settings.tacticalVioletTheme.foreground,
      );
    case TraversalSpeedProfile.walking:
      return Icon(
        LucideIcons.chevronUp,
        size: size,
        color: Settings.tacticalVioletTheme.foreground,
      );
    case TraversalSpeedProfile.brimStim:
      return Image.asset(
        'assets/agents/Brimstone/1.webp',
        width: size,
        height: size,
      );
    case TraversalSpeedProfile.neonRun:
      return Image.asset(
        'assets/agents/Neon/3.webp',
        width: size,
        height: size,
      );
  }
}

double _calculateTraversalTime({
  required FreeDrawing drawing,
  required double unitsPerMeter,
}) {
  if (drawing.listOfPoints.length < 2) return 0.0;

  double lengthUnits = 0.0;
  for (int i = 0; i < drawing.listOfPoints.length - 1; i++) {
    lengthUnits +=
        (drawing.listOfPoints[i + 1] - drawing.listOfPoints[i]).distance;
  }

  final distanceMeters = lengthUnits / unitsPerMeter;
  final speed = TraversalSpeed.metersPerSecond[drawing.traversalSpeedProfile] ??
      TraversalSpeed.metersPerSecond[TraversalSpeed.defaultProfile]!;
  if (speed <= 0) return 0.0;

  return distanceMeters / speed;
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
      } else if (elements[i] is RectangleDrawing) {
        final rectangle = elements[i] as RectangleDrawing;
        final screenRect = Rect.fromPoints(
          coordinateSystem.coordinateToScreen(rectangle.start),
          coordinateSystem.coordinateToScreen(rectangle.end),
        );

        if (rectangle.isDotted) {
          final space = coordinateSystem.scale(10);
          final rectPath = Path()..addRect(screenRect);
          DashPainter(span: space, step: space).paint(canvas, rectPath, paint);
        } else {
          canvas.drawRect(screenRect, paint);
        }
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
      } else if (currentLine is RectangleDrawing) {
        final rectangle = currentLine as RectangleDrawing;
        final screenRect = Rect.fromPoints(
          coordinateSystem.coordinateToScreen(rectangle.start),
          coordinateSystem.coordinateToScreen(rectangle.end),
        );

        if (rectangle.isDotted) {
          final space = coordinateSystem.scale(10);
          final rectPath = Path()..addRect(screenRect);
          DashPainter(span: space, step: space).paint(canvas, rectPath, paint);
        } else {
          canvas.drawRect(screenRect, paint);
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
