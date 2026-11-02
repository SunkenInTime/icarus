import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/keep_on_map_key_provider.dart';
import 'package:icarus/widgets/canvas_selection_layer.dart';

/// The [Draggable] of an item placed on the canvas. While Alt is held the
/// item stops at the edge of the map and slides along it, however far the
/// pointer goes: an item dropped past the edge is deleted, so this is how to
/// put one right beside it. See [CanvasSelectionLayer.keepOnMap] for where it
/// stops.
class CanvasDraggable<T extends Object> extends Draggable<T> {
  const CanvasDraggable({
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

  /// What was pressed. Flutter only hands the context to
  /// [dragAnchorStrategy], from the same call that starts the drag.
  static BuildContext? _pressed;

  @override
  DragAnchorStrategy get dragAnchorStrategy => (draggable, context, position) {
        _pressed = context;
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
      final limit = CanvasSelectionLayer.keepOnMap(pressed);
      if (limit == null) return drag;
      return _KeepOnMapDrag(
        drag,
        pressedAt: position,
        canvas: limit.canvas,
        keep: limit.keep,
        container: ProviderScope.containerOf(pressed, listen: false),
      );
    });
  }
}

/// Passes a drag along, stopping it where [keep] says while Alt is held. The
/// [Draggable] follows what it is told, so the preview, the drop and anything
/// watching the drag all agree on where the item is.
class _KeepOnMapDrag implements Drag {
  _KeepOnMapDrag(
    this._drag, {
    required this.pressedAt,
    required this.canvas,
    required this.keep,
    required ProviderContainer container,
  }) {
    // Alt can change with the pointer still, so it moves the item itself.
    _key = container.listen(keepOnMapKeyProvider, (_, held) {
      _held = held;
      _follow();
    });
    _held = _key.read();
  }

  final Drag _drag;
  final Offset pressedAt;
  final RenderBox canvas;

  /// Where a drag by a distance in the canvas's pixels stops.
  final Offset Function(Offset by) keep;

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
    final shown = _held ? _kept(_moved) : _moved;
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

  Offset _kept(Offset moved) {
    if (!canvas.attached) return moved;
    final from = canvas.globalToLocal(pressedAt);
    final by = canvas.globalToLocal(pressedAt + moved) - from;
    return canvas.localToGlobal(from + keep(by)) - pressedAt;
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
