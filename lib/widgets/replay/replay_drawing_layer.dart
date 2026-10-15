import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/main.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/replay/replay_drawing.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:icarus/widgets/drawing_painter.dart';
import 'package:icarus/widgets/replay/replay_select.dart';

/// What the user drew over the replay, painted by the editor's own drawing
/// painter. While the pen is out a drag here draws; otherwise every pointer
/// passes through to the map.
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

  @override
  Widget build(BuildContext context) {
    final drawing = widget.drawing;
    // The pen the editor would start with: the user's last colour and
    // thickness there.
    final preferences = ref.watch(appPreferencesProvider);
    final color = Color(preferences.drawingColorValue);
    final thickness =
        Settings.strokeThicknessOptions.contains(preferences.drawingThickness)
            ? preferences.drawingThickness
            : Settings.defaultStrokeThickness;
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
          return RepaintBoundary(
            child: Transform.flip(
              flipX: !isAttack,
              flipY: !isAttack,
              child: IgnorePointer(
                ignoring: !drawing.active,
                child: MouseRegion(
                  cursor: staticDrawingCursor ?? SystemMouseCursors.precise,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (details) => drawing.begin(
                      details.localPosition,
                      coordinates,
                      color: color,
                      thickness: thickness,
                    ),
                    onPanUpdate: (details) =>
                        drawing.extend(details.localPosition, coordinates),
                    onPanEnd: (_) => drawing.end(coordinates),
                    onPanCancel: () => drawing.end(coordinates),
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: DrawingPainter(
                        updateCounter: drawing.revision,
                        coordinateSystem: coordinates,
                        elements: drawing.strokes,
                        currentLine: drawing.current,
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
