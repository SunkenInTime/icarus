import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:icarus/const/bounding_box.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:uuid/uuid.dart';

/// The two ways to draw over a replay.
enum ReplayDrawingTool { freehand, arrow }

/// What the user draws over the paused replay. Strokes are the editor's own
/// drawing elements, in the same world coordinates as a page's, so they look
/// like editor drawings and a capture saves them as page drawings.
///
/// They mark up the moment on screen, so they go when it does: playing
/// clears them and puts the pen away, and moving the clock while paused
/// clears them. Nothing is saved by drawing.
class ReplayDrawing extends ChangeNotifier {
  ReplayDrawing(this.playback) : _timeMs = playback.timeMs {
    playback.addListener(_playbackChanged);
  }

  final ReplayPlayback playback;

  bool _active = false;
  ReplayDrawingTool _tool = ReplayDrawingTool.freehand;
  final List<DrawingElement> _strokes = [];
  DrawingElement? _current;
  int _revision = 0;
  int _timeMs;

  /// Whether a drag on the map draws rather than pans.
  bool get active => _active;
  ReplayDrawingTool get tool => _tool;

  /// The finished strokes, oldest first.
  List<DrawingElement> get strokes => List.unmodifiable(_strokes);

  /// The stroke under the pointer, until the drag ends.
  DrawingElement? get current => _current;

  /// Changes whenever what is drawn changes, for the painter.
  int get revision => _revision;

  /// Takes the pen out, pausing playback, or puts it away. Strokes stay
  /// either way.
  void toggle() => _active ? stop() : start();

  void start() {
    playback.pause();
    if (_active) return;
    _active = true;
    notifyListeners();
  }

  void stop() {
    if (!_active) return;
    _active = false;
    _current = null;
    _revision++;
    notifyListeners();
  }

  set tool(ReplayDrawingTool value) {
    if (_tool == value) return;
    _tool = value;
    notifyListeners();
  }

  /// Starts a stroke at [screenPoint], a point on the canvas in the
  /// attack-side world [coordinates] describe, as the editor's painter does.
  void begin(
    Offset screenPoint,
    CoordinateSystem coordinates, {
    required Color color,
    required double thickness,
  }) {
    if (!_active) return;
    final point = coordinates.screenToCoordinate(screenPoint);
    final id = const Uuid().v4();
    final box = BoundingBox(min: point, max: point);
    _current = switch (_tool) {
      ReplayDrawingTool.freehand => FreeDrawing(
          colorValue: color.toARGB32(),
          thickness: thickness,
          boundingBox: box,
          isDotted: false,
          hasArrow: false,
          id: id,
        )..appendPoint(point),
      ReplayDrawingTool.arrow => Line(
          lineStart: point,
          lineEnd: point,
          colorValue: color.toARGB32(),
          thickness: thickness,
          boundingBox: box,
          isDotted: false,
          hasArrow: true,
          id: id,
        ),
    };
    _changed();
  }

  /// Carries the stroke under the pointer on to [screenPoint].
  void extend(Offset screenPoint, CoordinateSystem coordinates) {
    final point = coordinates.screenToCoordinate(screenPoint);
    switch (_current) {
      case final FreeDrawing stroke:
        // The editor's spacing, so a stroke is as smooth here as there.
        final minDistance = coordinates.normalize(Settings.freeDrawMinDistance);
        if ((stroke.listOfPoints.last - point).distance < minDistance) return;
        stroke
          ..appendPoint(point)
          ..boundingBox = _grown(stroke.boundingBox!, point)
          ..rebuildPath(coordinates);
      case final Line line:
        line
          ..updateEndPoint(point)
          ..boundingBox = _grown(
            BoundingBox(min: line.lineStart, max: line.lineStart),
            point,
          );
      default:
        return;
    }
    _changed();
  }

  /// Ends the stroke under the pointer. A click that never moved draws
  /// nothing.
  void end(CoordinateSystem coordinates) {
    final stroke = _current;
    if (stroke == null) return;
    _current = null;
    switch (stroke) {
      case final FreeDrawing drawn when drawn.listOfPoints.length > 1:
        var finished = drawn;
        if (Settings.enableStrokeSimplification) {
          finished =
              douglasPeucker(finished, Settings.strokeSimplificationEpsilon);
        }
        _strokes.add(finished
          ..recomputeCachedPolylineLength()
          ..rebuildPath(coordinates));
      case final Line line when line.lineEnd != line.lineStart:
        _strokes.add(line);
      default:
        break;
    }
    _changed();
  }

  void clear() {
    if (_strokes.isEmpty && _current == null) return;
    _strokes.clear();
    _current = null;
    _changed();
  }

  /// Builds every freehand path again for a canvas of a new size. Doesn't
  /// notify: it runs while the layer that paints them builds.
  void rebuildPaths(CoordinateSystem coordinates) {
    for (final stroke in [..._strokes, if (_current != null) _current!]) {
      if (stroke is FreeDrawing) stroke.rebuildPath(coordinates);
    }
    _revision++;
  }

  /// Copies of the strokes for a captured page, sharing nothing with the
  /// ones on screen.
  List<DrawingElement> forCapture() =>
      [for (final stroke in _strokes) cloneDrawingElement(stroke)];

  void _playbackChanged() {
    final moved = playback.timeMs != _timeMs;
    _timeMs = playback.timeMs;
    if (playback.playing) {
      if (!_active && _strokes.isEmpty && _current == null) return;
      _active = false;
      _strokes.clear();
      _current = null;
      _changed();
    } else if (moved) {
      clear();
    }
  }

  void _changed() {
    _revision++;
    notifyListeners();
  }

  static BoundingBox _grown(BoundingBox box, Offset point) => BoundingBox(
        min: Offset(
          math.min(box.min.dx, point.dx),
          math.min(box.min.dy, point.dy),
        ),
        max: Offset(
          math.max(box.max.dx, point.dx),
          math.max(box.max.dy, point.dy),
        ),
      );

  @override
  void dispose() {
    playback.removeListener(_playbackChanged);
    super.dispose();
  }
}
