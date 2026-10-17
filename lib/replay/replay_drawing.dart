import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:icarus/const/bounding_box.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/pen_provider.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:uuid/uuid.dart';

/// What the user draws over the paused replay. Strokes are the editor's own
/// drawing elements, drawn with the editor's pen, in the same world
/// coordinates as a page's, so they look like editor drawings and a capture
/// saves them as page drawings.
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
  bool _erasing = false;
  final List<DrawingElement> _strokes = [];
  DrawingElement? _current;
  int _revision = 0;
  int _timeMs;

  /// Whether a drag on the map draws or erases rather than pans.
  bool get active => _active;

  /// Whether the drag erases, as the editor's eraser does.
  bool get erasing => _erasing;

  /// The finished strokes, oldest first.
  List<DrawingElement> get strokes => List.unmodifiable(_strokes);

  /// The stroke under the pointer, until the drag ends.
  DrawingElement? get current => _current;

  /// Changes whenever what is drawn changes, for the painter.
  int get revision => _revision;

  /// Takes the pen out, pausing playback, or puts it away; with the eraser
  /// out, swaps it for the pen. Strokes stay either way.
  void toggle() => _active && !_erasing ? stop() : start();

  /// Takes the eraser out, or puts it away; with the pen out, swaps it for
  /// the eraser.
  void toggleEraser() => _erasing ? stop() : start(erasing: true);

  void start({bool erasing = false}) {
    playback.pause();
    if (_active && _erasing == erasing) return;
    _active = true;
    _erasing = erasing;
    _current = null;
    _changed();
  }

  void stop() {
    if (!_active) return;
    _active = false;
    _erasing = false;
    _current = null;
    _changed();
  }

  /// Starts a stroke at [screenPoint], a point on the canvas in the
  /// attack-side world [coordinates] describe, as the editor's painter does,
  /// in the shape and style of [pen].
  void begin(Offset screenPoint, CoordinateSystem coordinates, PenState pen) {
    if (!_active || _erasing) return;
    final point = coordinates.screenToCoordinate(screenPoint);
    final id = const Uuid().v4();
    final box = BoundingBox(min: point, max: point);
    final colorValue = pen.color.toARGB32();
    _current = switch (pen.penMode) {
      PenMode.freeDraw => FreeDrawing(
          colorValue: colorValue,
          thickness: pen.thickness,
          boundingBox: box,
          isDotted: pen.isDotted,
          hasArrow: pen.hasArrow,
          id: id,
          showTraversalTime: pen.traversalTimeEnabled,
          traversalSpeedProfile: pen.activeTraversalSpeedProfile,
        )..appendPoint(point),
      PenMode.line => Line(
          lineStart: point,
          lineEnd: point,
          colorValue: colorValue,
          thickness: pen.thickness,
          boundingBox: box,
          isDotted: pen.isDotted,
          hasArrow: pen.hasArrow,
          id: id,
          showTraversalTime: pen.traversalTimeEnabled,
          traversalSpeedProfile: pen.activeTraversalSpeedProfile,
        ),
      // The editor's shapes take neither an arrow nor a traversal time.
      PenMode.square => RectangleDrawing(
          start: point,
          end: point,
          colorValue: colorValue,
          thickness: pen.thickness,
          isDotted: pen.isDotted,
          hasArrow: false,
          id: id,
          boundingBox: box,
        ),
      PenMode.ellipse => EllipseDrawing(
          start: point,
          end: point,
          colorValue: colorValue,
          thickness: pen.thickness,
          isDotted: pen.isDotted,
          hasArrow: false,
          id: id,
          boundingBox: box,
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
      case final RectangleDrawing shape:
        shape.updateEndPoint(point);
        shape.boundingBox = _boxOf(shape.normalizedRect);
      case final EllipseDrawing shape:
        shape.updateEndPoint(point);
        shape.boundingBox = _boxOf(shape.normalizedRect);
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
      case final RectangleDrawing shape when shape.end != shape.start:
        _strokes.add(shape);
      case final EllipseDrawing shape when shape.end != shape.start:
        _strokes.add(shape);
      default:
        break;
    }
    _changed();
  }

  /// Rubs out every stroke within the editor's eraser of [screenPoint].
  void erase(Offset screenPoint, CoordinateSystem coordinates) {
    if (!_erasing) return;
    final point = coordinates.screenToCoordinate(screenPoint);
    final before = _strokes.length;
    _strokes.removeWhere(
      (stroke) => isNearDrawing(stroke, point, Settings.erasingSize),
    );
    if (_strokes.length != before) _changed();
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
      _erasing = false;
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

  static BoundingBox _boxOf(Rect rect) =>
      BoundingBox(min: rect.topLeft, max: rect.bottomRight);

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
