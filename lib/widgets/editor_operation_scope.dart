import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/canvas_selection_provider.dart';
import 'package:icarus/providers/collab/editing_presence_provider.dart';
import 'package:icarus/providers/editor_operation_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/widgets/strategy_presence.dart';

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
/// wait; the rest of the page updates. While a teammate is changing it, its
/// [EditorItemOutline] is drawn in their color, and while it is selected, in
/// the selection's.
///
/// The item sits in its own full-size layer so its positioned widget lays out
/// exactly as before, and the listener only fires when the item itself is hit.
class EditorEntityLayer extends ConsumerWidget {
  const EditorEntityLayer({
    required this.id,
    required this.kind,
    required this.child,
    this.selectionId,
    super.key,
  });

  final String id;

  /// What the selection calls the item, when that can't be [id]: see
  /// [originEndId].
  final String? selectionId;

  /// What the item is, for selecting it. A lineup's throw spot and landing
  /// are [SelectableKind.lineup] under their own ids.
  final SelectableKind kind;

  /// A [Positioned] (or similar) item widget.
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectionId = this.selectionId ?? id;
    void hold(PointerEvent event) {
      final pointers = ref.read(editorPointersProvider.notifier);
      pointers.holdEntity(event.pointer, id);
      pointers.holdEntity(event.pointer, selectionId);
    }

    // While the selection is dragged, an item it carries is drawn where the
    // drag has carried it; it moves for real when the drag ends.
    final shift = ref.watch(
      canvasGroupDragProvider.select(
        (drag) => drag != null && drag.ids.contains(id) ? drag.by : null,
      ),
    );
    return Positioned.fill(
      child: Listener(
        behavior: HitTestBehavior.deferToChild,
        onPointerDown: hold,
        onPointerPanZoomStart: hold,
        // Always here, so the item keeps its state when a drag starts.
        child: Transform.translate(
          offset: shift ?? Offset.zero,
          child: _DragsWithSelection(
            value: ref.watch(dragsWithSelectionProvider(selectionId)),
            child: ItemOutlineScope(
              id: id,
              selectionId: selectionId,
              kind: kind,
              child: Stack(clipBehavior: Clip.none, children: [child]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Whether the item below is one of several selected items that move
/// together (see [itemDragLimit]).
class _DragsWithSelection extends InheritedWidget {
  const _DragsWithSelection({required this.value, required super.child});

  final bool value;

  @override
  bool updateShouldNotify(_DragsWithSelection oldWidget) =>
      value != oldWidget.value;
}

/// The `maxSimultaneousDrags` of a canvas item's own [Draggable]: none while
/// the item is one of several selected, so a drag on it moves the whole
/// selection instead (the canvas's selection drag takes it). Its handles
/// and taps are left as they are.
int? itemDragLimit(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<_DragsWithSelection>()?.value ??
            false
        ? 0
        : null;

/// Draws the [EditorItemOutline]s under it in the color of the teammate
/// changing item [id], if anyone is, and in the selection's color while the
/// item is selected. With a [kind], its outline is also what a selection box
/// on the canvas measures the item by (see [CanvasItemRegistry]).
class ItemOutlineScope extends ConsumerWidget {
  const ItemOutlineScope({
    required this.id,
    required this.child,
    this.kind,
    this.selectionId,
    super.key,
  });

  final String id;
  final SelectableKind? kind;

  /// What the selection calls the item, when that isn't [id].
  final String? selectionId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editor = ref.watch(itemEditorsProvider.select((items) => items[id]));
    final selectionId = this.selectionId ?? id;
    final selected = kind != null &&
        ref.watch(
          selectedCanvasIdsProvider.select(
            (ids) => ids.contains(selectionId),
          ),
        );
    final outlined = editor != null || selected;
    return _ItemOutlineStyle(
      item: kind == null ? null : (kind: kind!, id: selectionId),
      color: editor == null ? null : presenceColorFor(editor.uid),
      selected: selected,
      // The outline keeps its width on screen at any zoom; only an outlined
      // item rebuilds as the zoom changes.
      zoom: outlined ? ref.watch(screenZoomProvider) : 1,
      child: child,
    );
  }
}

/// How the [EditorItemOutline]s of one item draw: in [color] for the
/// teammate changing it, and in the selection's color when [selected]; not
/// at all when neither.
class _ItemOutlineStyle extends InheritedWidget {
  const _ItemOutlineStyle({
    required this.item,
    required this.color,
    required this.selected,
    required this.zoom,
    required super.child,
  });

  final SelectedItem? item;
  final Color? color;
  final bool selected;
  final double zoom;

  @override
  bool updateShouldNotify(_ItemOutlineStyle oldWidget) =>
      item != oldWidget.item ||
      color != oldWidget.color ||
      selected != oldWidget.selected ||
      zoom != oldWidget.zoom;
}

/// The items drawn on the canvas, each measured by the outline of what it
/// draws, so a selection box finds them where the user sees them: on either
/// side of the map, at any agent or ability size, turned however far.
class CanvasItemRegistry {
  final _outlines = <RenderEditorItemOutline>{};

  /// Each item on the canvas with its outline's corners in the coordinates
  /// of [canvas], in order around the outline (a turned item gives a turned
  /// rectangle).
  Iterable<({SelectedItem item, List<Offset> corners})> itemsIn(
    RenderBox canvas,
  ) sync* {
    for (final outline in _outlines) {
      final item = outline._item;
      if (item == null || outline._inner > 0 || !outline.hasSize) continue;
      if (!_isUnder(outline, canvas)) continue;
      final transform = outline.getTransformTo(canvas);
      final rect = Offset.zero & outline.size;
      yield (
        item: item,
        corners: [
          for (final corner in [
            rect.topLeft,
            rect.topRight,
            rect.bottomRight,
            rect.bottomLeft,
          ])
            MatrixUtils.transformPoint(transform, corner),
        ],
      );
    }
  }

  static bool _isUnder(RenderObject node, RenderObject ancestor) {
    for (RenderObject? at = node; at != null; at = at.parent) {
      if (identical(at, ancestor)) return true;
    }
    return false;
  }
}

/// Hands the canvas's [CanvasItemRegistry] to the [EditorItemOutline]s
/// under it. Outlines with no registry above them (captures, drag
/// feedback) can't be selected.
class CanvasItemRegistryScope extends InheritedWidget {
  const CanvasItemRegistryScope({
    required this.registry,
    required super.child,
    super.key,
  });

  final CanvasItemRegistry registry;

  static CanvasItemRegistry? maybeOf(BuildContext context) => context
      .getInheritedWidgetOfExactType<CanvasItemRegistryScope>()
      ?.registry;

  @override
  bool updateShouldNotify(CanvasItemRegistryScope oldWidget) =>
      registry != oldWidget.registry;
}

/// The shape a canvas item draws, which is outlined while a teammate is
/// changing the item or while it is selected. It sits inside the item's
/// rotation, so the outline turns with it. Outside an [ItemOutlineScope] (a drag's feedback, an
/// export) it draws nothing.
///
/// Every item marks what it draws. An item that lays out in a box larger
/// than it draws (room for a cone or circle at its largest) also marks its
/// drawn part inside, and the innermost mark is the one outlined.
class EditorItemOutline extends SingleChildRenderObjectWidget {
  const EditorItemOutline({required super.child, super.key});

  @override
  RenderObject createRenderObject(BuildContext context) {
    final style =
        context.dependOnInheritedWidgetOfExactType<_ItemOutlineStyle>();
    return RenderEditorItemOutline(
      color: style?.color,
      selected: style?.selected ?? false,
      zoom: style?.zoom ?? 1,
      item: style?.item,
      registry: CanvasItemRegistryScope.maybeOf(context),
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderEditorItemOutline renderObject,
  ) {
    final style =
        context.dependOnInheritedWidgetOfExactType<_ItemOutlineStyle>();
    renderObject
      ..color = style?.color
      ..selected = style?.selected ?? false
      ..zoom = style?.zoom ?? 1
      ..item = style?.item
      ..registry = CanvasItemRegistryScope.maybeOf(context);
  }
}

class RenderEditorItemOutline extends RenderProxyBox {
  RenderEditorItemOutline({
    required Color? color,
    required bool selected,
    required double zoom,
    SelectedItem? item,
    CanvasItemRegistry? registry,
  })  : _color = color,
        _selected = selected,
        _zoom = zoom,
        _item = item,
        _registry = registry;

  /// On screen, in logical pixels.
  static const double _width = 2;
  static const double _gap = 3;
  static const double _radius = 6;

  Color? _color;
  set color(Color? value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  bool _selected;
  set selected(bool value) {
    if (value == _selected) return;
    _selected = value;
    markNeedsPaint();
  }

  double _zoom;
  set zoom(double value) {
    if (value == _zoom) return;
    _zoom = value;
    markNeedsPaint();
  }

  SelectedItem? _item;
  set item(SelectedItem? value) => _item = value;

  CanvasItemRegistry? _registry;
  set registry(CanvasItemRegistry? value) {
    if (identical(value, _registry)) return;
    if (attached) {
      _registry?._outlines.remove(this);
      value?._outlines.add(this);
    }
    _registry = value;
  }

  /// The mark this one is inside, and how many marks are inside this one.
  RenderEditorItemOutline? _outer;
  int _inner = 0;

  void _changeInner(int by) {
    _inner += by;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    var node = parent;
    while (node != null && node is! RenderEditorItemOutline) {
      node = node.parent;
    }
    _outer = node as RenderEditorItemOutline?;
    _outer?._changeInner(1);
    _registry?._outlines.add(this);
  }

  @override
  void detach() {
    _registry?._outlines.remove(this);
    _outer?._changeInner(-1);
    _outer = null;
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (_inner > 0) return;
    final scale = 1 / _zoom;
    var gap = _gap;
    void outline(Color color) {
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(
          (offset & size).inflate((gap + _width / 2) * scale),
          Radius.circular((_radius + gap - _gap) * scale),
        ),
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = _width * scale,
      );
      // A teammate's outline goes around the selection's, so both show.
      gap += _width + _gap;
    }

    // Only the canvas shows a selection; a capture of the page never does.
    if (_selected && _registry != null) {
      outline(Settings.tacticalVioletTheme.primary);
    }
    if (_color case final color?) outline(color);
  }
}
