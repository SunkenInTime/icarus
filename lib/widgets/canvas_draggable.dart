import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/snap_to_map_key_provider.dart';
import 'package:icarus/widgets/canvas_selection_layer.dart';

/// The [Draggable] of an item placed on the canvas. While Alt is held the
/// item's [dot] snaps onto the nearest line the map draws and slides along
/// it: see [CanvasSelectionLayer.snapToMap].
class CanvasDraggable<T extends Object> extends Draggable<T> {
  const CanvasDraggable({
    required this.dot,
    required super.child,
    required super.feedback,
    super.data,
    super.childWhenDragging,
    super.feedbackOffset,
    super.dragAnchorStrategy,
    super.maxSimultaneousDrags,
    super.onDragStarted,
    super.onDragUpdate,
    super.onDraggableCanceled,
    super.onDragEnd,
    super.onDragCompleted,
    super.key,
  });

  /// Where the item's dot is, in world units with the attack side up: its
  /// saved position plus the anchor its drop goes by (a picture or a note,
  /// which have none, use their middle). This is the point Alt puts on a line.
  final Offset dot;

  /// What was pressed, and where its dot was then. Flutter only hands the
  /// context to [dragAnchorStrategy], from the same call that starts the
  /// drag, and builds the recognizer with the first widget, so the dot is
  /// read from the widget pressed rather than this one.
  static ({BuildContext context, Offset dot})? _pressed;

  @override
  DragAnchorStrategy get dragAnchorStrategy => (draggable, context, position) {
        _pressed = (
          context: context,
          dot: (draggable as CanvasDraggable).dot,
        );
        return super.dragAnchorStrategy(draggable, context, position);
      };

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) {
    return super.createRecognizer((position) {
      final drag = onStart(position);
      final pressed = _pressed;
      _pressed = null;
      if (drag == null || pressed == null) return drag;
      final snap = CanvasSelectionLayer.snapToMap(pressed.context, pressed.dot);
      if (snap == null) return drag;
      return _SnapToMapDrag(
        drag,
        pressedAt: position,
        canvas: snap.canvas,
        snap: snap.snap,
        container: ProviderScope.containerOf(pressed.context, listen: false),
      );
    });
  }
}

/// Passes a drag along, moved where [snap] says while Alt is held. The
/// [Draggable] follows what it is told, so the preview, the drop and anything
/// watching the drag all agree on where the item is.
class _SnapToMapDrag implements Drag {
  _SnapToMapDrag(
    this._drag, {
    required this.pressedAt,
    required this.canvas,
    required this.snap,
    required ProviderContainer container,
  }) {
    // Alt can change with the pointer still, so it moves the item itself.
    _key = container.listen(snapToMapKeyProvider, (_, held) {
      _held = held;
      _follow();
    });
    _held = _key.read();
  }

  final Drag _drag;
  final Offset pressedAt;
  final RenderBox canvas;

  /// Where a drag by a distance in the canvas's pixels goes instead.
  final Offset Function(Offset by) snap;

  late final ProviderSubscription<bool> _key;
  bool _held = false;

  /// How far the pointer has gone since the press, and how far the drag was
  /// told it has gone, both in global pixels.
  Offset _moved = Offset.zero;
  Offset _shown = Offset.zero;

  @override
  void update(DragUpdateDetails details) {
    _moved += details.delta;
    _follow(details.sourceTimeStamp);
  }

  void _follow([Duration? timeStamp]) {
    final shown = _held ? _snapped(_moved) : _moved;
    final delta = shown - _shown;
    _shown = shown;
    _drag.update(
      DragUpdateDetails(
        sourceTimeStamp: timeStamp,
        delta: delta,
        globalPosition: pressedAt + shown,
      ),
    );
  }

  Offset _snapped(Offset moved) {
    if (!canvas.attached) return moved;
    final from = canvas.globalToLocal(pressedAt);
    final by = canvas.globalToLocal(pressedAt + moved) - from;
    return canvas.localToGlobal(from + snap(by)) - pressedAt;
  }

  @override
  void end(DragEndDetails details) {
    _key.close();
    _drag.end(details);
  }

  @override
  void cancel() {
    _key.close();
    _drag.cancel();
  }
}
