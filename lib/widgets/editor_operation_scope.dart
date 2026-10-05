import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/editor_operation_provider.dart';

/// Includes sidebar drags and controls in overlays as well as the canvas.
class EditorOperationScope extends ConsumerStatefulWidget {
  const EditorOperationScope({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<EditorOperationScope> createState() =>
      _EditorOperationScopeState();
}

class _EditorOperationScopeState extends ConsumerState<EditorOperationScope> {
  /// Pointer id to the device that pressed it. Trackpad pan/zoom gestures map
  /// to null: the cursor may hover while two fingers are still down.
  final _pointers = <int, int?>{};
  late EditorPointersNotifier _notifier;

  @override
  void initState() {
    super.initState();
    _notifier = ref.read(editorPointersProvider.notifier);
  }

  void _hold(int pointer, int? device) {
    _pointers[pointer] = device;
    _notifier.down(pointer);
  }

  void _release(PointerEvent event) {
    _pointers.remove(event.pointer);
    _notifier.release(event.pointer);
  }

  /// A hovering device has no buttons down. If its up event was lost (for
  /// example, released outside the window), stop holding back remote updates.
  void _releaseDevice(PointerEvent event) {
    final stale = [
      for (final entry in _pointers.entries)
        if (entry.value == event.device) entry.key,
    ];
    for (final pointer in stale) {
      _pointers.remove(pointer);
      _notifier.release(pointer);
    }
  }

  @override
  void dispose() {
    for (final pointer in _pointers.keys) {
      _notifier.release(pointer);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) => _hold(event.pointer, event.device),
        onPointerUp: _release,
        onPointerCancel: _release,
        // Trackpad pinches and two-finger drags reach the same onPan* handlers
        // as a pressed pointer, so they hold remote updates back too.
        onPointerPanZoomStart: (event) => _hold(event.pointer, null),
        onPointerPanZoomEnd: _release,
        onPointerHover: _releaseDevice,
        child: widget.child,
      );
}

/// The strategy canvas. A press here that lands on no item (drawing, panning)
/// holds nothing back: remote changes keep arriving while it lasts.
class EditorCanvasRegion extends ConsumerWidget {
  const EditorCanvasRegion({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void mark(PointerEvent event) =>
        ref.read(editorPointersProvider.notifier).markCanvas(event.pointer);
    // Translucent: any press inside the canvas counts, even where the canvas
    // widgets under it only listen.
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: mark,
      onPointerPanZoomStart: mark,
      child: child,
    );
  }
}

/// One canvas item, as a child of the canvas's item [Stack]. While a press on
/// it (a drag, a rotate or resize handle) lasts, remote changes to this item
/// wait; the rest of the page updates.
///
/// The item sits in its own full-size layer so its positioned widget lays out
/// exactly as before, and the listener only fires when the item itself is hit.
class EditorEntityLayer extends ConsumerWidget {
  const EditorEntityLayer({required this.id, required this.child, super.key});

  final String id;

  /// A [Positioned] (or similar) item widget.
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void hold(PointerEvent event) =>
        ref.read(editorPointersProvider.notifier).holdEntity(event.pointer, id);
    return Positioned.fill(
      child: Listener(
        behavior: HitTestBehavior.deferToChild,
        onPointerDown: hold,
        onPointerPanZoomStart: hold,
        child: Stack(clipBehavior: Clip.none, children: [child]),
      ),
    );
  }
}
