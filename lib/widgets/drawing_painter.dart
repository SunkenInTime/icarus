import 'dart:developer';
import 'dart:math' as math;

import 'package:dash_painter/dash_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/maps.dart';
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
  const InteractivePainter({
    super.key,
    this.mapScaleOverride,
    this.isAttackOverride,
  });

  final double? mapScaleOverride;
  final bool? isAttackOverride;

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
    final currentMap =
        ref.watch(mapProvider.select((state) => state.currentMap));
    final double mapScale =
        widget.mapScaleOverride ?? (Maps.mapScale[currentMap] ?? 1.0);
    final bool isAttack = widget.isAttackOverride ??
        ref.watch(mapProvider.select((state) => state.isAttack));

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
                  switch (penState.penMode) {
                    case PenMode.freeDraw:
                      ref.read(drawingProvider.notifier).startFreeDrawing(
                            details.localPosition,
                            coordinateSystem,
                            penState.color,
                            penState.thickness,
                            penState.isDotted,
                            penState.hasArrow,
                            penState.traversalTimeEnabled,
                            penState.activeTraversalSpeedProfile,
                          );
                    case PenMode.line:
                      ref.read(drawingProvider.notifier).startLine(
                            details.localPosition,
                            coordinateSystem,
                            penState.color,
                            penState.thickness,
                            penState.isDotted,
                            penState.hasArrow,
                            penState.traversalTimeEnabled,
                            penState.activeTraversalSpeedProfile,
                          );
                    case PenMode.square:
                      ref.read(drawingProvider.notifier).startRectangle(
                            details.localPosition,
                            coordinateSystem,
                            penState.color,
                            penState.thickness,
                            penState.isDotted,
                          );
                    case PenMode.ellipse:
                      ref.read(drawingProvider.notifier).startEllipse(
                            details.localPosition,
                            coordinateSystem,
                            penState.color,
                            penState.thickness,
                            penState.isDotted,
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
                  switch (penState.penMode) {
                    case PenMode.freeDraw:
                      ref.read(drawingProvider.notifier).updateFreeDrawing(
                          details.localPosition, coordinateSystem);
                    case PenMode.line:
                      ref.read(drawingProvider.notifier).updateCurrentLine(
                            details.localPosition,
                            coordinateSystem,
                          );
                    case PenMode.square:
                      ref.read(drawingProvider.notifier).updateRectangle(
                            details.localPosition,
                            coordinateSystem,
                          );
                    case PenMode.ellipse:
                      ref.read(drawingProvider.notifier).updateEllipse(
                            details.localPosition,
                            coordinateSystem,
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
            onPanEnd: (details) {
              switch (currentInteractionState) {
                case InteractionState.drawing:
                  switch (penState.penMode) {
                    case PenMode.freeDraw:
                      ref
                          .read(drawingProvider.notifier)
                          .finishFreeDrawing(null, coordinateSystem);
                    case PenMode.line:
                      ref
                          .read(drawingProvider.notifier)
                          .finishCurrentLine(null, coordinateSystem);
                    case PenMode.square:
                      ref
                          .read(drawingProvider.notifier)
                          .finishRectangle(null, coordinateSystem);
                    case PenMode.ellipse:
                      ref
                          .read(drawingProvider.notifier)
                          .finishEllipse(null, coordinateSystem);
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
                                  .withValues(alpha: 0.5),
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
      for (final element in elements)
        if (_showsTraversalTime(element))
          _buildTraversalCard(
            element: element,
            coordinateSystem: coordinateSystem,
            mapScale: mapScale,
            isAttack: isAttack,
          ),
      if (currentLine != null && _showsTraversalTime(currentLine!))
        _buildTraversalCard(
          element: currentLine!,
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
  required DrawingElement element,
  required CoordinateSystem coordinateSystem,
  required double mapScale,
  required bool isAttack,
}) {
  final anchor = _traversalAnchor(element);
  if (anchor == null) return const SizedBox.shrink();

  final unitsPerMeter = AgentData.inGameMeters * mapScale;
  if (unitsPerMeter <= 0) return const SizedBox.shrink();

  const cardWidthMeters = 8.0 * 7;
  const cardHeightMeters = 3.5 * 7;
  const xOffsetMeters = 0.8;
  const yOffsetMeters = 0.8;

  final cardWidthScreen = coordinateSystem.scale(cardWidthMeters);
  final cardHeightScreen = coordinateSystem.scale(cardHeightMeters);
  final cardTopLeft = anchor.translate(
    xOffsetMeters * unitsPerMeter,
    -yOffsetMeters * unitsPerMeter,
  );
  final anchorScreen = coordinateSystem.coordinateToScreen(cardTopLeft);

  final timeSeconds = _calculateTraversalTime(
    element: element,
    unitsPerMeter: unitsPerMeter,
  );
  final label = "${timeSeconds.toStringAsFixed(2)}s";
  final labelStyle = TextStyle(
    fontSize: coordinateSystem.scale(10),
    color: Settings.tacticalVioletTheme.foreground,
    fontWeight: FontWeight.w600,
    decoration: TextDecoration.none,
  );
  final iconSize = coordinateSystem.scale(10).clamp(10.0, 20.0).toDouble();
  final leadingIcon = _buildTraversalModeIcon(
    profile: _traversalProfile(element),
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
                  style: labelStyle,
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
  required DrawingElement element,
  required double unitsPerMeter,
}) {
  double lengthUnits;
  if (element is FreeDrawing) {
    if (element.listOfPoints.length < 2) return 0.0;

    lengthUnits = element.cachedPolylineLengthUnits;
    if (!lengthUnits.isFinite || lengthUnits < 0) {
      lengthUnits = 0.0;
      for (int i = 0; i < element.listOfPoints.length - 1; i++) {
        lengthUnits +=
            (element.listOfPoints[i + 1] - element.listOfPoints[i]).distance;
      }
    }
  } else if (element is Line) {
    lengthUnits = (element.lineEnd - element.lineStart).distance;
  } else {
    return 0.0;
  }

  final distanceMeters = lengthUnits / unitsPerMeter;
  final speed = TraversalSpeed.metersPerSecond[_traversalProfile(element)] ??
      TraversalSpeed.metersPerSecond[TraversalSpeed.defaultProfile]!;
  if (speed <= 0) return 0.0;

  return distanceMeters / speed;
}

bool _showsTraversalTime(DrawingElement element) {
  return switch (element) {
    FreeDrawing drawing => drawing.showTraversalTime,
    Line line => line.showTraversalTime,
    _ => false,
  };
}

TraversalSpeedProfile _traversalProfile(DrawingElement element) {
  return switch (element) {
    FreeDrawing drawing => drawing.traversalSpeedProfile,
    Line line => line.traversalSpeedProfile,
    _ => TraversalSpeed.defaultProfile,
  };
}

Offset? _traversalAnchor(DrawingElement element) {
  return switch (element) {
    FreeDrawing drawing when drawing.listOfPoints.isNotEmpty =>
      drawing.listOfPoints.last,
    Line line => line.lineEnd,
    _ => null,
  };
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
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true
      ..strokeCap = StrokeCap.round;

    // Helper function to draw an arrow
    void drawArrow(
      Canvas canvas,
      Paint paint,
      Offset from,
      Offset to,
      double thickness,
    ) {
      final arrowHeadSize = 8 * (thickness / Settings.defaultStrokeThickness);
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

    void paintLine(Canvas canvas, Paint paint, Line line) {
      paint.strokeWidth = coordinateSystem.scale(line.thickness);
      final screenStartOffset =
          coordinateSystem.coordinateToScreen(line.lineStart);
      final screenEndOffset = coordinateSystem.coordinateToScreen(line.lineEnd);

      if (line.isDotted) {
        final space = coordinateSystem.scale(10);
        final linePath = Path()
          ..moveTo(screenStartOffset.dx, screenStartOffset.dy)
          ..lineTo(screenEndOffset.dx, screenEndOffset.dy);
        DashPainter(span: space, step: space).paint(canvas, linePath, paint);
      } else {
        canvas.drawLine(screenStartOffset, screenEndOffset, paint);
      }

      if (line.hasArrow) {
        drawArrow(
          canvas,
          paint,
          screenStartOffset,
          screenEndOffset,
          line.thickness,
        );
      }
    }

    void paintEllipse(Canvas canvas, Paint paint, EllipseDrawing ellipse) {
      paint.strokeWidth = coordinateSystem.scale(ellipse.thickness);
      final screenRect = Rect.fromPoints(
        coordinateSystem.coordinateToScreen(ellipse.start),
        coordinateSystem.coordinateToScreen(ellipse.end),
      );

      if (ellipse.isDotted) {
        final space = coordinateSystem.scale(10);
        final ovalPath = Path()..addOval(screenRect);
        DashPainter(span: space, step: space).paint(canvas, ovalPath, paint);
      } else {
        canvas.drawOval(screenRect, paint);
      }
    }

    for (int i = 0; i < elements.length; i++) {
      paint.color = elements[i].color;
      if (elements[i] is Line) {
        paintLine(canvas, paint, elements[i] as Line);
      } else if (elements[i] is RectangleDrawing) {
        final rectangle = elements[i] as RectangleDrawing;
        paint.strokeWidth = coordinateSystem.scale(rectangle.thickness);
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
      } else if (elements[i] is EllipseDrawing) {
        paintEllipse(canvas, paint, elements[i] as EllipseDrawing);
      } else if (elements[i] is FreeDrawing) {
        FreeDrawing freeDrawing = elements[i] as FreeDrawing;
        paint.strokeWidth = coordinateSystem.scale(freeDrawing.thickness);
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
          drawArrow(canvas, paint, from, to, freeDrawing.thickness);
        }
      }
    }

    if (currentLine != null) {
      paint.color = currentLine!.color;
      if (currentLine is FreeDrawing) {
        final drawingElement = currentLine as FreeDrawing;
        paint.strokeWidth = coordinateSystem.scale(drawingElement.thickness);

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
          drawArrow(canvas, paint, from, to, drawingElement.thickness);
        }
      } else if (currentLine is Line) {
        paintLine(canvas, paint, currentLine as Line);
      } else if (currentLine is RectangleDrawing) {
        final rectangle = currentLine as RectangleDrawing;
        paint.strokeWidth = coordinateSystem.scale(rectangle.thickness);
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
      } else if (currentLine is EllipseDrawing) {
        paintEllipse(canvas, paint, currentLine as EllipseDrawing);
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
