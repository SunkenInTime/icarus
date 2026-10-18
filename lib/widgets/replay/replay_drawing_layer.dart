import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/main.dart';
import 'package:icarus/providers/pen_provider.dart';
import 'package:icarus/replay/replay_drawing.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:icarus/widgets/cursor_circle.dart';
import 'package:icarus/widgets/drawing_painter.dart';
import 'package:icarus/widgets/replay/replay_select.dart';

/// What the user drew over the replay, painted by the editor's own drawing
/// painter. While the pen is out a drag here draws with the editor's pen,
/// and while the eraser is out it rubs out under the editor's eraser ring;
/// otherwise every pointer passes through to the map.
///
/// The layer sits in the canvas's world, so strokes zoom and pan with the
/// map. Strokes are stored in the attack-side world like everything placed,
/// and the layer is flipped on defense, as the editor flips a page's
/// drawings. It repaints only when the strokes change.
class ReplayDrawingLayer extends ConsumerStatefulWidget {
  const ReplayDrawingLayer({
    super.key,
    required this.drawing,
    required this.playback,
  });

  final ReplayDrawing drawing;
  final ReplayPlayback playback;

  @override
  ConsumerState<ReplayDrawingLayer> createState() => _ReplayDrawingLayerState();
}

class _ReplayDrawingLayerState extends ConsumerState<ReplayDrawingLayer> {
  /// The canvas size the freehand paths were last built for.
  Size? _pathsSize;

  /// Where the pointer is over the map, pen out or not, so the eraser's
  /// ring is under it the moment the eraser comes out.
  final _pointer = ValueNotifier<Offset?>(null);

  @override
  void dispose() {
    _pointer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final drawing = widget.drawing;
    // The editor's pen, so a stroke here is drawn as one there would be.
    final pen = ref.watch(penProvider);
    final mapScale =
        Maps.mapScale[widget.playback.frames.projection.map] ?? 1.0;
    return ReplaySelect(
      listenable: widget.playback,
      select: () => widget.playback.frame.isAttack,
      builder: (context, isAttack) => ListenableBuilder(
        listenable: drawing,
        builder: (context, _) {
          final coordinates = CoordinateSystem.instance;
          if (_pathsSize != coordinates.effectiveSize) {
            _pathsSize = coordinates.effectiveSize;
            drawing.rebuildPaths(coordinates);
          }
          final ring = coordinates.scale(Settings.erasingSize * 2);
          return RepaintBoundary(
            child: Transform.flip(
              flipX: !isAttack,
              flipY: !isAttack,
              // Watches the pointer without taking it from the map below.
              child: MouseRegion(
                opaque: false,
                onHover: (event) => _pointer.value = event.localPosition,
                onExit: (_) => _pointer.value = null,
                child: IgnorePointer(
                  ignoring: !drawing.active,
                  child: MouseRegion(
                    cursor: drawing.erasing
                        ? SystemMouseCursors.none
                        : pen.drawingCursor ??
                            staticDrawingCursor ??
                            SystemMouseCursors.precise,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (details) {
                        _pointer.value = details.localPosition;
                        if (drawing.erasing) {
                          drawing.erase(details.localPosition, coordinates);
                        } else {
                          drawing.begin(
                              details.localPosition, coordinates, pen);
                        }
                      },
                      onPanUpdate: (details) {
                        _pointer.value = details.localPosition;
                        if (drawing.erasing) {
                          drawing.erase(details.localPosition, coordinates);
                        } else {
                          drawing.extend(details.localPosition, coordinates);
                        }
                      },
                      onPanEnd: (_) => drawing.end(coordinates),
                      onPanCancel: () => drawing.end(coordinates),
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: CustomPaint(
                              painter: DrawingPainter(
                                updateCounter: drawing.revision,
                                coordinateSystem: coordinates,
                                elements: drawing.strokes,
                                currentLine: drawing.current,
                              ),
                            ),
                          ),
                          Positioned.fill(
                            child: IgnorePointer(
                              child: TraversalTimeOverlay(
                                coordinateSystem: coordinates,
                                mapScale: mapScale,
                                isAttack: isAttack,
                                elements: drawing.strokes,
                                currentLine: drawing.current,
                              ),
                            ),
                          ),
                          ValueListenableBuilder(
                            valueListenable: _pointer,
                            builder: (context, at, _) =>
                                at == null || !drawing.erasing
                                    ? const SizedBox.shrink()
                                    : Positioned(
                                        left: at.dx - ring / 2,
                                        top: at.dy - ring / 2,
                                        child: IgnorePointer(
                                          child: CursorCircle(
                                            size: ring,
                                            ringThickness: 1,
                                            gap: 1,
                                            ringColor: Settings
                                                .tacticalVioletTheme
                                                .destructive,
                                            fillColor: Settings
                                                .tacticalVioletTheme.destructive
                                                .withValues(alpha: 0.5),
                                          ),
                                        ),
                                      ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
