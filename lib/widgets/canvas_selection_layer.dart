import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/shortcut_info.dart';
import 'package:icarus/providers/canvas_selection_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/editor_operation_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/widgets/editor_operation_scope.dart';

/// Whether Space is held to move the map: while it is, a drag anywhere on
/// the canvas moves the map instead of selecting or moving what it lands on.
final canvasPanKeyHeldProvider =
    NotifierProvider<_CanvasPanKeyHeld, bool>(_CanvasPanKeyHeld.new);

class _CanvasPanKeyHeld extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool held) {
    if (state != held) state = held;
  }
}

/// The strategy canvas in navigation mode, as a whiteboard: a drag on an
/// empty part of the map draws a box that selects what it covers, a click
/// selects an item (Shift adds or removes it), and holding Space turns
/// every drag into moving the map. [child] is the canvas, in the canvas's
/// own coordinates (the same space items are laid out in).
///
/// The map's own pan and zoom stay with the [InteractiveViewer] around this:
/// the box is a mouse gesture, so a touch drag, a trackpad's two fingers, a
/// middle-button drag and the scroll wheel move and zoom the map as before.
///
/// A press on the canvas gives it the keyboard, so the selection's keys
/// (Escape, Delete, Backspace, select all) and Space reach it, and never
/// fire from a dialog, a menu or the library.
class CanvasSelectionLayer extends ConsumerStatefulWidget {
  const CanvasSelectionLayer({
    required this.enabled,
    required this.child,
    super.key,
  });

  /// Selecting is possible: the navigation tool is on and the page can be
  /// edited. Space still moves the map when this is false.
  final bool enabled;

  final Widget child;

  @override
  ConsumerState<CanvasSelectionLayer> createState() =>
      _CanvasSelectionLayerState();
}

class _CanvasSelectionLayerState extends ConsumerState<CanvasSelectionLayer>
    with WidgetsBindingObserver {
  final _registry = CanvasItemRegistry();
  final _canvasKey = GlobalKey();
  final _focus = FocusNode(debugLabel: 'strategy-canvas', skipTraversal: true);

  /// The box being drawn, in canvas coordinates, while a drag lasts, and
  /// the corner it is drawn from.
  Rect? _box;
  Offset? _boxOrigin;
  bool _boxAdds = false;

  /// The press that may become a click: where it went down, and whether a
  /// box or a drag of the selection has started from it since.
  int? _clickPointer;
  Offset? _clickDown;

  /// The item the press landed on, before a drag of the selection holds the
  /// rest of the selection under the same pointer.
  Set<String> _clickHeld = const {};
  bool _pressBecameDrag = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_releaseSpace);
    _groupDrag = ref.read(canvasGroupDragProvider.notifier);
  }

  late final CanvasGroupDragNotifier _groupDrag;

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_releaseSpace);
    WidgetsBinding.instance.removeObserver(this);
    // A drag the canvas leaves mid-way (the editor closed) is dropped, not
    // left drawn where it had carried its items.
    if (_dragPointer != null) scheduleMicrotask(() => _groupDrag.set(null));
    _focus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A Space released while the window was in the background never comes.
    if (state != AppLifecycleState.resumed) {
      ref.read(canvasPanKeyHeldProvider.notifier).set(false);
    }
  }

  /// Lets go of Space wherever the keyboard is by then: a Space held on the
  /// canvas can be released after a click moved the focus away.
  bool _releaseSpace(KeyEvent event) {
    if (event is KeyUpEvent && event.logicalKey == LogicalKeyboardKey.space) {
      ref.read(canvasPanKeyHeldProvider.notifier).set(false);
    }
    return false;
  }

  /// Whether the key goes to a text field on the canvas (a text item being
  /// written), where every key keeps its usual meaning.
  static bool _typing() {
    final context = FocusManager.instance.primaryFocus?.context;
    return context != null &&
        (context.widget is EditableText ||
            context.findAncestorStateOfType<EditableTextState>() != null);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_typing()) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      if (event is! KeyUpEvent) {
        ref.read(canvasPanKeyHeldProvider.notifier).set(true);
      }
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.escape && _dragOrigin != null) {
      // Escape drops the drag; everything stays where it was.
      _dragDropped = true;
      ref.read(canvasGroupDragProvider.notifier).set(null);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && _box != null) {
      // Escape drops the box being drawn; the selection stays as it was.
      _boxOrigin = null;
      setState(() => _box = null);
      return KeyEventResult.handled;
    }
    if (!widget.enabled) return KeyEventResult.ignored;
    final selection = ref.read(canvasSelectionProvider.notifier);
    final hasSelection = ref.read(canvasSelectionProvider).isNotEmpty;
    if (key == LogicalKeyboardKey.escape && hasSelection) {
      selection.clear();
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.delete ||
            key == LogicalKeyboardKey.backspace) &&
        hasSelection) {
      selection.deleteSelected();
      return KeyEventResult.handled;
    }
    final selectAll = ShortcutInfo.effectiveBindingFor(
      IcarusShortcutAction.selectAll.name,
      ref.read(appPreferencesProvider).customShortcutBindings,
    ).toActivator();
    if (selectAll.accepts(event, HardwareKeyboard.instance)) {
      selection.selectAll();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The first time a drag on the map draws a box instead of moving the map,
  /// says why while the drag is still under the user's hand, and how to
  /// move the map now.
  void _teachOnce() {
    final preferences = ref.read(appPreferencesProvider);
    if (preferences.canvasSelectionHintSeen) return;
    ref.read(appPreferencesProvider.notifier).markCanvasSelectionHintSeen();
    Settings.showToast(
      message: 'Dragging on the map now selects. Hold Space and drag to '
          'move the map.',
      backgroundColor: Settings.tacticalVioletTheme.primary,
      autoCloseDuration: const Duration(seconds: 8),
    );
  }

  RenderBox? get _canvas =>
      _canvasKey.currentContext?.findRenderObject() as RenderBox?;

  bool get _shiftHeld => HardwareKeyboard.instance.isShiftPressed;

  void _onBoxStart(DragStartDetails details) {
    _boxAdds = _shiftHeld;
    _boxOrigin = details.localPosition;
  }

  void _onBoxUpdate(DragUpdateDetails details) {
    final origin = _boxOrigin;
    if (origin == null) return;
    // A box exists once the pointer has moved: a press that won the gesture
    // only because nothing else wanted it is still a click.
    if (!_pressBecameDrag) _teachOnce();
    _pressBecameDrag = true;
    setState(() => _box = Rect.fromPoints(origin, details.localPosition));
  }

  void _onBoxEnd(DragEndDetails details) {
    final box = _box;
    _boxOrigin = null;
    setState(() => _box = null);
    if (box == null) return;
    final found = _itemsIn(box);
    final selection = ref.read(canvasSelectionProvider.notifier);
    _boxAdds ? selection.add(found) : selection.select(found);
  }

  void _onBoxCancel() {
    _boxOrigin = null;
    setState(() => _box = null);
  }

  /// What [box] selects. Things that mark a spot (agents, abilities,
  /// utilities, a lineup's two ends) count when their middle is inside it;
  /// text, images and drawings, which cover an area, when all of them is.
  Set<SelectedItem> _itemsIn(Rect box) {
    final canvas = _canvas;
    if (canvas == null) return const {};
    final found = <SelectedItem>{};
    final lineupEnds = <String>{};
    for (final (:item, :corners) in _registry.itemsIn(canvas)) {
      final inside = switch (item.kind) {
        SelectableKind.text ||
        SelectableKind.image =>
          corners.every(box.contains),
        _ => box.contains(_middle(corners)),
      };
      if (!inside) continue;
      if (item.kind == SelectableKind.lineup) {
        lineupEnds.add(item.id);
      } else {
        found.add(item);
      }
    }
    // A lineup comes in whole: both its throw spot and landing are inside.
    for (final link in ref.read(lineUpProvider).links) {
      if (lineupEnds.contains(link.originId) &&
          lineupEnds.contains(link.landingId)) {
        found.add((kind: SelectableKind.lineup, id: link.id));
      }
    }
    for (final drawing in ref.read(drawingProvider).elements) {
      final bounds = drawing.boundingBox;
      if (bounds == null) continue;
      if (box.contains(_drawn(bounds.min)) &&
          box.contains(_drawn(bounds.max))) {
        found.add((kind: SelectableKind.drawing, id: drawing.id));
      }
    }
    return found;
  }

  static Offset _middle(List<Offset> corners) =>
      corners.reduce((a, b) => a + b) / corners.length.toDouble();

  bool get _isAttack => ref.read(mapProvider).isAttack;

  /// Where a point stored in world coordinates is drawn on the canvas.
  /// Drawings are stored attack side up and turned with the map.
  Offset _drawn(Offset world) {
    final coordinates = CoordinateSystem.instance;
    final attack = coordinates.coordinateToScreen(world);
    return _isAttack ? attack : _flip(attack, coordinates.playAreaSize);
  }

  /// The world point drawn at [onCanvas].
  Offset _stored(Offset onCanvas) {
    final coordinates = CoordinateSystem.instance;
    final attack =
        _isAttack ? onCanvas : _flip(onCanvas, coordinates.playAreaSize);
    return coordinates.screenToCoordinate(attack);
  }

  /// The defense side is the attack layout turned half a circle.
  static Offset _flip(Offset point, Size canvas) =>
      canvas.bottomRight(Offset.zero) - point;

  void _onPointerDown(PointerDownEvent event) {
    // The canvas takes the keyboard, except from a text item, which takes it
    // itself to be written in.
    final held =
        ref.read(editorPointersProvider)[event.pointer]?.entityIds ?? const {};
    if (!ref.read(textProvider).any((text) => held.contains(text.id))) {
      // After this press is handled: a text item being written lets go of
      // the keyboard when pressed outside, and must not hand it to the page
      // after the canvas took it.
      scheduleMicrotask(() {
        if (mounted) _focus.requestFocus();
      });
    }
    _pressBecameDrag = false;
    if (!widget.enabled ||
        event.kind != PointerDeviceKind.mouse ||
        event.buttons != kPrimaryMouseButton ||
        ref.read(canvasPanKeyHeldProvider)) {
      _clickPointer = null;
      return;
    }
    _clickPointer = event.pointer;
    _clickDown = event.position;
    _clickHeld = held;
  }

  void _onPointerUp(PointerUpEvent event) {
    // A press that never moved draws no box and drags nothing, even when a
    // drag won it only because nothing else wanted it (it ends after this).
    if (!_pressBecameDrag) {
      _boxOrigin = null;
      if (event.pointer == _dragPointer) _endDrag();
    }
    if (event.pointer != _clickPointer) return;
    _clickPointer = null;
    final down = _clickDown;
    if (_pressBecameDrag || down == null) return;
    // A press that moved is a drag of something, not a click.
    if ((event.position - down).distance > kTouchSlop) return;
    _click(event);
  }

  void _click(PointerUpEvent event) {
    final selection = ref.read(canvasSelectionProvider.notifier);
    final hit = _clickedItem(_clickHeld, event);
    if (hit == null) {
      if (!_shiftHeld) selection.clear();
      return;
    }
    // Clicking a lineup opens it; it is selected with a box.
    if (hit.kind == SelectableKind.lineup) return;
    _shiftHeld ? selection.toggle(hit) : selection.select([hit]);
  }

  /// The item a click landed on: the canvas item its press held, or else a
  /// drawing under it (drawings are painted, so they hold nothing).
  SelectedItem? _clickedItem(Set<String> heldIds, PointerUpEvent event) {
    final canvas = _canvas;
    if (canvas == null) return null;
    if (heldIds.isNotEmpty) {
      for (final (:item, corners: _) in _registry.itemsIn(canvas)) {
        if (heldIds.contains(item.id)) return item;
      }
      return null;
    }
    return _drawingAt(event.position);
  }

  /// The drawing on top under the screen point [global], if any.
  SelectedItem? _drawingAt(Offset global) {
    final canvas = _canvas;
    if (canvas == null) return null;
    final point = _stored(canvas.globalToLocal(global));
    final zoom = ref.read(screenZoomProvider);
    final reach = CoordinateSystem.instance
        .screenToCoordinate(Offset(_clickReach / zoom, 0))
        .dx;
    final drawings = ref.read(drawingProvider).elements;
    // The one drawn last is on top.
    for (final drawing in drawings.reversed) {
      if (isNearDrawing(drawing, point, reach)) {
        return (kind: SelectableKind.drawing, id: drawing.id);
      }
    }
    return null;
  }

  /// How far from a stroke a click still selects it, in screen pixels.
  static const double _clickReach = 6;

  /// Whether a press takes hold of the selection to drag it: it lands on a
  /// selected item that moves, and there is more than that item to move. A
  /// lone selected item drags as it always has (Ctrl to copy it, onto an
  /// agent to join it); a drawing has no drag of its own, so it is taken
  /// alone too. The items it would carry are noted now, as they are.
  bool _grabsSelection(PointerDownEvent event) {
    if (!widget.enabled || ref.read(canvasPanKeyHeldProvider)) return false;
    final selection = ref.read(canvasSelectionProvider);
    final held =
        ref.read(editorPointersProvider)[event.pointer]?.entityIds ?? const {};
    final pressed = held.isNotEmpty
        ? held
        : {if (_drawingAt(event.position) case final drawing?) drawing.id};
    final grabbed = [
      for (final item in selection)
        if (movesWithSelection(item.kind) && pressed.contains(item.id)) item,
    ];
    if (grabbed.isEmpty) return false;
    if (selection.length == 1 &&
        grabbed.single.kind != SelectableKind.drawing) {
      return false;
    }
    _dragPointer = event.pointer;
    _dragIds = {
      for (final item in selection)
        if (movesWithSelection(item.kind)) item.id,
    };
    return true;
  }

  /// The drag of the selection: the pointer that pressed it, the items it
  /// carries (fixed when it began, whatever the selection does meanwhile),
  /// where it began, how far it may go each way so nothing leaves the map,
  /// and whether Escape dropped it.
  int? _dragPointer;
  Set<String>? _dragIds;
  Offset? _dragOrigin;
  Rect _dragRoom = Rect.zero;
  bool _dragDropped = false;

  void _onDragStart(DragStartDetails details) {
    final ids = _dragIds;
    final pointer = _dragPointer;
    if (ids == null || pointer == null) return;
    _dragOrigin = details.localPosition;
    _dragDropped = false;
    _dragRoom = _roomToMove(ids);
    // A teammate's change to what is being dragged waits for the drop.
    final pointers = ref.read(editorPointersProvider.notifier);
    for (final id in ids) {
      pointers.holdEntity(pointer, id);
    }
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final origin = _dragOrigin;
    final ids = _dragIds;
    if (origin == null || ids == null || _dragDropped) return;
    final moved = details.localPosition - origin;
    _pressBecameDrag = true;
    ref.read(canvasGroupDragProvider.notifier).set((
      ids: ids,
      by: Offset(
        moved.dx.clamp(_dragRoom.left, _dragRoom.right),
        moved.dy.clamp(_dragRoom.top, _dragRoom.bottom),
      ),
    ));
  }

  void _onDragEnd(DragEndDetails details) {
    final drag = ref.read(canvasGroupDragProvider);
    final dropped = _dragDropped;
    _endDrag();
    if (drag == null || dropped) return;
    // The drag moved what is drawn; items are saved attack side up.
    final world = CoordinateSystem.instance.screenToCoordinate(drag.by);
    ref
        .read(canvasSelectionProvider.notifier)
        .moveItems(drag.ids, _isAttack ? world : -world);
  }

  void _endDrag() {
    _dragPointer = null;
    _dragIds = null;
    _dragOrigin = null;
    if (ref.read(canvasGroupDragProvider) != null) {
      ref.read(canvasGroupDragProvider.notifier).set(null);
    }
  }

  /// How far the items [ids] can be dragged each way, in canvas pixels,
  /// before the middle of one of them would leave the map.
  Rect _roomToMove(Set<String> ids) {
    final canvas = _canvas;
    if (canvas == null) return Rect.zero;
    final points = <Offset>[
      for (final (:item, :corners) in _registry.itemsIn(canvas))
        if (ids.contains(item.id)) _middle(corners),
      for (final drawing in ref.read(drawingProvider).elements)
        if (ids.contains(drawing.id))
          if (drawing.boundingBox case final bounds?) ...[
            _drawn(bounds.min),
            _drawn(bounds.max),
          ],
    ];
    if (points.isEmpty) return Rect.zero;
    final coordinates = CoordinateSystem.instance;
    // Clear of the edge where a drop deletes (CoordinateSystem.isOutOfBounds).
    final margin = coordinates.coordinateToScreen(const Offset(20, 0)).dx;
    final size = coordinates.playAreaSize;
    var spread = Rect.fromPoints(points.first, points.first);
    for (final point in points.skip(1)) {
      spread = spread.expandToInclude(Rect.fromPoints(point, point));
    }
    final left = math.min(0.0, margin - spread.left);
    final top = math.min(0.0, margin - spread.top);
    return Rect.fromLTRB(
      left,
      top,
      math.max(left, size.width - margin - spread.right),
      math.max(top, size.height - margin - spread.bottom),
    );
  }

  /// The selected drawings' extents on the canvas. Drawings are painted, not
  /// laid out, so their outline is drawn here rather than by the item.
  List<Rect> _selectedDrawingOutlines() {
    final ids = ref.watch(selectedDrawingIdsProvider);
    if (ids.isEmpty) return const [];
    // They follow a drag of the selection, as the drawings do.
    final drag = ref.watch(canvasGroupDragProvider);
    return [
      for (final drawing in ref.watch(drawingProvider).elements)
        if (ids.contains(drawing.id))
          if (drawing.boundingBox case final bounds?)
            Rect.fromPoints(_drawn(bounds.min), _drawn(bounds.max))
                .inflate(
                  CoordinateSystem.instance.scale(drawing.thickness) / 2,
                )
                .shift(
                  drag != null && drag.ids.contains(drawing.id)
                      ? drag.by
                      : Offset.zero,
                ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final panHeld = ref.watch(canvasPanKeyHeldProvider);
    final selecting = widget.enabled && !panHeld;
    return CanvasItemRegistryScope(
      registry: _registry,
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: MouseRegion(
          cursor: panHeld ? SystemMouseCursors.grab : MouseCursor.defer,
          child: Listener(
            onPointerDown: _onPointerDown,
            onPointerUp: _onPointerUp,
            child: RawGestureDetector(
              behavior: HitTestBehavior.opaque,
              gestures: {
                // Kept while one is under way, so Space or a tool change
                // can't drop it half done.
                if (selecting || _dragPointer != null)
                  _SelectionDragRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                          _SelectionDragRecognizer>(
                    _SelectionDragRecognizer.new,
                    (recognizer) => recognizer
                      ..grabs = _grabsSelection
                      ..dragStartBehavior = DragStartBehavior.down
                      ..onStart = _onDragStart
                      ..onUpdate = _onDragUpdate
                      ..onEnd = _onDragEnd
                      ..onCancel = _endDrag,
                  ),
                if (selecting || _boxOrigin != null)
                  _BoxRecognizer:
                      GestureRecognizerFactoryWithHandlers<_BoxRecognizer>(
                    _BoxRecognizer.new,
                    (recognizer) => recognizer
                      // Not a press the selection's drag took, nor one with Space
                      // held (read at the press: no frame may have passed).
                      ..allows = ((event) =>
                          event.pointer != _dragPointer &&
                          !ref.read(canvasPanKeyHeldProvider))
                      ..dragStartBehavior = DragStartBehavior.down
                      ..onStart = _onBoxStart
                      ..onUpdate = _onBoxUpdate
                      ..onEnd = _onBoxEnd
                      ..onCancel = _onBoxCancel,
                  ),
              },
              child: Stack(
                key: _canvasKey,
                clipBehavior: Clip.none,
                children: [
                  // With Space held, the press goes past the items to the
                  // map, which moves.
                  IgnorePointer(ignoring: panHeld, child: widget.child),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _SelectedDrawingsPainter(
                          outlines: _selectedDrawingOutlines(),
                          zoom: ref.watch(screenZoomProvider),
                        ),
                      ),
                    ),
                  ),
                  if (_box case final box?)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _SelectionBoxPainter(
                            box: box,
                            zoom: ref.watch(screenZoomProvider),
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
    );
  }
}

/// Outlines the selected drawings the way [EditorItemOutline] outlines a
/// selected item: a rounded box a few pixels clear of it.
class _SelectedDrawingsPainter extends CustomPainter {
  _SelectedDrawingsPainter({required this.outlines, required this.zoom});

  final List<Rect> outlines;
  final double zoom;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = 1 / zoom;
    final paint = Paint()
      ..color = Settings.tacticalVioletTheme.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * scale;
    for (final outline in outlines) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          outline.inflate(4 * scale),
          Radius.circular(6 * scale),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_SelectedDrawingsPainter oldDelegate) =>
      zoom != oldDelegate.zoom || !_sameRects(outlines, oldDelegate.outlines);

  static bool _sameRects(List<Rect> a, List<Rect> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _SelectionBoxPainter extends CustomPainter {
  _SelectionBoxPainter({required this.box, required this.zoom});

  final Rect box;
  final double zoom;

  @override
  void paint(Canvas canvas, Size size) {
    final violet = Settings.tacticalVioletTheme.primary;
    canvas.drawRect(box, Paint()..color = violet.withValues(alpha: 0.12));
    canvas.drawRect(
      box,
      Paint()
        ..color = violet
        ..style = PaintingStyle.stroke
        // One pixel on screen at any zoom.
        ..strokeWidth = 1 / zoom,
    );
  }

  @override
  bool shouldRepaint(_SelectionBoxPainter oldDelegate) =>
      box != oldDelegate.box || zoom != oldDelegate.zoom;
}

/// Drags the selection from a press on one of its items. It competes like
/// any drag: an item's handles still win their own drags, and a tap still
/// reaches the item; the items' own drags stand aside (see itemDragLimit).
class _SelectionDragRecognizer extends PanGestureRecognizer {
  // Every device whose drags the items would otherwise take: their own drag
  // stands aside while they are selected together.
  _SelectionDragRecognizer()
      : super(
          supportedDevices: const {
            PointerDeviceKind.mouse,
            PointerDeviceKind.touch,
            PointerDeviceKind.stylus,
            PointerDeviceKind.invertedStylus,
          },
          allowedButtonsFilter: (buttons) => buttons == kPrimaryMouseButton,
        );

  late bool Function(PointerDownEvent event) grabs;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      super.isPointerAllowed(event) &&
      (event is! PointerDownEvent || grabs(event));
}

/// Draws a selection box from a press the selection's drag did not take.
class _BoxRecognizer extends PanGestureRecognizer {
  _BoxRecognizer()
      : super(
          supportedDevices: const {PointerDeviceKind.mouse},
          allowedButtonsFilter: (buttons) => buttons == kPrimaryMouseButton,
        );

  late bool Function(PointerDownEvent event) allows;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      super.isPointerAllowed(event) &&
      (event is! PointerDownEvent || allows(event));
}
