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
import 'package:icarus/providers/canvas_clipboard_provider.dart';
import 'package:icarus/providers/canvas_selection_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/editor_operation_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/map_lines_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/snap_to_map_key_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/services/clipboard_service.dart';
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

/// Whether the keyboard is in a text field (a text item being written, say),
/// where every key keeps its usual meaning.
bool isTypingInTextField() {
  final context = FocusManager.instance.primaryFocus?.context;
  return context != null &&
      (context.widget is EditableText ||
          context.findAncestorStateOfType<EditableTextState>() != null);
}

/// The strategy canvas as a whiteboard: a drag on an empty part of the map
/// draws a box that selects what it covers, a click selects an item (Shift
/// adds or removes it), and holding Space turns every drag into moving the
/// map. [child] is the canvas, in the canvas's own coordinates (the same
/// space items are laid out in).
///
/// The map's own pan and zoom stay with the [InteractiveViewer] around this:
/// the box is a mouse gesture, so a touch drag, a trackpad's two fingers, a
/// middle-button drag and the scroll wheel move and zoom the map as before.
///
/// A press on the canvas gives it the keyboard, so the selection's keys
/// (Escape, Delete, Backspace, select all, copy, cut) and Space reach it, and
/// never fire from a dialog, a menu or the library. Paste belongs to the
/// whole editor: see CanvasPaste.
class CanvasSelectionLayer extends ConsumerStatefulWidget {
  /// See [_CanvasSelectionLayerState._snapToMap]. Null when [pressed] isn't
  /// on a canvas.
  static ({RenderBox canvas, Offset Function(Offset by) snap})? snapToMap(
    BuildContext pressed,
    Offset dot,
  ) =>
      pressed
          .findAncestorStateOfType<_CanvasSelectionLayerState>()
          ?._snapToMap(dot);

  /// The part of the canvas on screen, in its pixels: the canvas runs on
  /// past the window and under the sidebar. Null when [context] isn't on a
  /// canvas.
  static Rect? viewOf(BuildContext context) => context
      .findAncestorStateOfType<_CanvasSelectionLayerState>()
      ?._onScreen;

  const CanvasSelectionLayer({
    required this.enabled,
    required this.child,
    this.view,
    super.key,
  });

  /// The part of the canvas on screen right now, in its pixels. Without one,
  /// all of it is.
  final Rect Function()? view;

  /// Selecting is possible: no tool takes the canvas's drags and the page
  /// can be edited. A lineup mode narrows it to the ends being placed or
  /// edited. Space still moves the map when this is false.
  final bool enabled;

  final Widget child;

  @override
  ConsumerState<CanvasSelectionLayer> createState() =>
      _CanvasSelectionLayerState();
}

class _CanvasSelectionLayerState extends ConsumerState<CanvasSelectionLayer>
    with WidgetsBindingObserver {
  CanvasItemRegistry get _registry => ref.read(canvasItemRegistryProvider);
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

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (isTypingInTextField()) return KeyEventResult.ignored;
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
      _moveLineUpEnds(Offset.zero);
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
    // The page is out of reach, and the keys below are all for the page.
    if (_lineUpMode) return KeyEventResult.ignored;
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
    bool primaryWith(LogicalKeyboardKey key) =>
        IcarusKeyBinding(trigger: key, primary: true)
            .toActivator()
            .accepts(event, HardwareKeyboard.instance);
    if (primaryWith(LogicalKeyboardKey.keyC) && hasSelection) {
      _copy();
      return KeyEventResult.handled;
    }
    if (primaryWith(LogicalKeyboardKey.keyX) && hasSelection) {
      unawaited(_cut());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  CanvasClipboard? _copy() {
    final clipboard = ref.read(canvasClipboardProvider.notifier);
    final copied = clipboard.copySelection(
      (pictures) => readCopiedPictures(ref, pictures),
    );
    if (copied == 0) return null;
    // A copy replaces what the system clipboard held, as it does anywhere
    // else, so a picture found there later was copied after this.
    unawaited(ClipboardService.clear());
    return ref.read(canvasClipboardProvider);
  }

  /// Copies the selection, then deletes it once its pictures are read: a
  /// deleted picture may not be there to read later. Only what was cut is
  /// deleted, and only while its page is still the one on screen.
  Future<void> _cut() async {
    final cut = ref.read(canvasSelectionProvider);
    final page = ref.read(strategyPageSessionProvider).activePageId;
    final copied = _copy();
    if (copied == null) return;
    await copied.pictures;
    if (!mounted ||
        ref.read(strategyPageSessionProvider).activePageId != page) {
      return;
    }
    ref.read(canvasSelectionProvider.notifier).deleteItems(cut);
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

  /// What [box] selects: everything it touches as drawn. An item counts
  /// when the box touches its outline, a drawing when the box crosses its
  /// stroke, so a long diagonal line isn't taken by a box near its middle.
  Set<SelectedItem> _itemsIn(Rect box) {
    final canvas = _canvas;
    if (canvas == null) return const {};
    if (_lineUpMode) {
      return {
        for (final (:item, :corners) in _registry.itemsIn(canvas))
          if (item.kind == SelectableKind.lineupEnd && _touches(box, corners))
            item,
      };
    }
    final found = <SelectedItem>{};
    final lineupEnds = <String>{};
    for (final (:item, :corners) in _registry.itemsIn(canvas)) {
      if (!_touches(box, corners)) continue;
      if (item.kind == SelectableKind.lineup) {
        lineupEnds.add(item.id);
      } else {
        found.add(item);
      }
    }
    // A lineup comes in whole: the box touches its throw spot and landing.
    for (final link in ref.read(lineUpProvider).links) {
      if (lineupEnds.contains(link.originId) &&
          lineupEnds.contains(link.landingId)) {
        found.add((kind: SelectableKind.lineup, id: link.id));
      }
    }
    final coordinates = CoordinateSystem.instance;
    // Drawings are painted attack side up and turned with the map.
    final painted = _isAttack
        ? box
        : Rect.fromPoints(
            _flip(box.topLeft, coordinates.playAreaSize),
            _flip(box.bottomRight, coordinates.playAreaSize),
          );
    for (final drawing in ref.read(drawingProvider).elements) {
      // Wide by half the stroke, so the edge of a thick stroke counts.
      final reach = painted.inflate(coordinates.scale(drawing.thickness) / 2);
      if (drawingCrosses(drawing, reach)) {
        found.add((kind: SelectableKind.drawing, id: drawing.id));
      }
    }
    return found;
  }

  /// Whether [box] and the outline through [corners], a rectangle that may
  /// be turned, share any point. Two convex shapes miss each other exactly
  /// when, along the normal of one of their edges, their shadows don't
  /// overlap.
  static bool _touches(Rect box, List<Offset> corners) {
    final rect = [box.topLeft, box.topRight, box.bottomRight, box.bottomLeft];
    for (final shape in [rect, corners]) {
      for (var i = 0; i < shape.length; i++) {
        final edge = shape[(i + 1) % shape.length] - shape[i];
        if (_apartAlong(Offset(-edge.dy, edge.dx), rect, corners)) {
          return false;
        }
      }
    }
    return true;
  }

  static bool _apartAlong(Offset axis, List<Offset> a, List<Offset> b) {
    double along(Offset point) => point.dx * axis.dx + point.dy * axis.dy;
    final onA = a.map(along).toList();
    final onB = b.map(along).toList();
    return onA.reduce(math.max) < onB.reduce(math.min) ||
        onB.reduce(math.max) < onA.reduce(math.min);
  }

  bool get _lineUpMode => ref.read(interactionStateProvider).isLineUpMode;

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
    if (canvas == null || _lineUpMode) return null;
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
    _dragDot = _dotOf(pressed, event.position);
    return true;
  }

  /// The point of what a press took hold of that Alt puts on the map's
  /// lines, in world units, attack side up: the middle of the item pressed,
  /// or for a drawing, the point pressed on it.
  Offset? _dotOf(Set<String> pressed, Offset global) {
    final canvas = _canvas;
    if (canvas == null) return null;
    for (final (:item, :corners) in _registry.itemsIn(canvas)) {
      if (pressed.contains(item.id)) return _stored(_middle(corners));
    }
    return _stored(canvas.globalToLocal(global));
  }

  /// The drag of the selection: the pointer that pressed it, the items it
  /// carries (fixed when it began, whatever the selection does meanwhile),
  /// where it began, how far it may go each way so nothing leaves the map,
  /// and whether Escape dropped it.
  int? _dragPointer;
  Set<String>? _dragIds;
  Offset? _dragOrigin;
  Offset? _dragDot;

  /// How far the pointer has gone since the drag began, for Alt to move the
  /// items again when it changes with the pointer still.
  Offset _dragMoved = Offset.zero;
  Rect _dragRoom = Rect.zero;
  bool _dragDropped = false;

  /// Where the lineup ends the drag carries were when it began. Unlike the
  /// page's items they move as the drag goes, so the lines into them follow.
  Map<String, Offset> _dragEndsFrom = const {};

  void _onDragStart(DragStartDetails details) {
    final ids = _dragIds;
    final pointer = _dragPointer;
    if (ids == null || pointer == null) return;
    _dragOrigin = details.localPosition;
    _dragMoved = Offset.zero;
    _dragDropped = false;
    _dragRoom = _roomToMove(ids);
    _dragEndsFrom = {
      for (final MapEntry(key: id, value: position)
          in ref.read(lineUpProvider).movableEnds.entries)
        if (ids.contains(id)) id: position,
    };
    // A teammate's change to what is being dragged waits for the drop.
    final pointers = ref.read(editorPointersProvider.notifier);
    for (final id in ids) {
      pointers.holdEntity(pointer, id);
    }
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final origin = _dragOrigin;
    if (origin == null) return;
    _pressBecameDrag = true;
    _dragTo(details.localPosition - origin);
  }

  /// Moves what the drag carries by [moved], or onto the map's lines from
  /// there while Alt is held, as far as [_dragRoom] lets it go.
  void _dragTo(Offset moved) {
    final ids = _dragIds;
    if (ids == null || _dragDropped) return;
    _dragMoved = moved;
    final dot = _dragDot;
    if (dot != null && ref.read(snapToMapKeyProvider)) {
      moved = _snapped(moved, dot);
    }
    final by = Offset(
      moved.dx.clamp(_dragRoom.left, _dragRoom.right),
      moved.dy.clamp(_dragRoom.top, _dragRoom.bottom),
    );
    if (_dragEndsFrom.isNotEmpty) {
      _moveLineUpEnds(by);
    } else {
      ref.read(canvasGroupDragProvider.notifier).set((ids: ids, by: by));
    }
  }

  /// Puts the lineup ends the drag carries [by] from where it began.
  void _moveLineUpEnds(Offset by) {
    final world = CoordinateSystem.instance.screenToCoordinate(by);
    ref
        .read(lineUpProvider.notifier)
        .moveEndsFrom(_dragEndsFrom, _isAttack ? world : -world);
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
    _dragDot = null;
    _dragEndsFrom = const {};
    if (ref.read(canvasGroupDragProvider) != null) {
      ref.read(canvasGroupDragProvider.notifier).set(null);
    }
  }

  /// How far the items [ids] can be dragged each way, in canvas pixels,
  /// before the middle of one of them would leave the part of the map on
  /// screen, or the map when they are spread wider than that.
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
    // Clear of the edge where a drop deletes (CoordinateSystem.isOutOfBounds).
    final margin = CoordinateSystem.instance
        .coordinateToScreen(const Offset(20, 0))
        .dx;
    final spread = _spreadOf(points);
    return _roomInside(
      spread,
      _inSight(spread, _map.deflate(margin), _onScreen.deflate(margin)),
    );
  }

  /// The part of the map on screen, in canvas pixels.
  Rect get _onScreen => widget.view?.call().intersect(_map) ?? _map;

  /// Where [spread] has to stay to be seen: in [view], except along an axis
  /// it is too big for, where it stays on [map].
  static Rect _inSight(Rect spread, Rect map, Rect view) => Rect.fromLTRB(
        spread.width > view.width ? map.left : view.left,
        spread.height > view.height ? map.top : view.top,
        spread.width > view.width ? map.right : view.right,
        spread.height > view.height ? map.bottom : view.bottom,
      );

  /// The canvas, and where a drag of an item whose dot is at [dot] by a
  /// given distance in its pixels goes while Alt is held. See [_snapped].
  ({RenderBox canvas, Offset Function(Offset by) snap})? _snapToMap(
    Offset dot,
  ) {
    final canvas = _canvas;
    if (canvas == null) return null;
    return (canvas: canvas, snap: (by) => _snapped(by, dot));
  }

  /// [by], a drag in canvas pixels of something whose dot is at [dot], moved
  /// so the dot lands on the nearest line the map draws, when there is one
  /// within [_snapReach] of where it would be. Otherwise it is [by]: away
  /// from every line the drag goes where the pointer does. [dot] is in world
  /// units, attack side up. Only lines where a drop would leave the dot
  /// count: a drop brings a dot near the edge of the view in from it
  /// (CoordinateSystem.showing), which would take it off the line.
  Offset _snapped(Offset by, Offset dot) {
    final map = ref.read(mapProvider).currentMap;
    final lines = ref.read(mapLinesProvider(map)).valueOrNull;
    if (lines == null) return by;
    final coordinates = CoordinateSystem.instance;
    // The defense side draws the attack side turned half a turn.
    Offset turned(Offset by) => _isAttack ? by : -by;
    final reach = coordinates
        .screenToCoordinate(
          Offset(_snapReach / ref.read(screenZoomProvider), 0),
        )
        .dx;
    final onLine = lines.nearest(
      dot + turned(coordinates.screenToCoordinate(by)),
      reach,
      within: coordinates.inSight(_onScreen, isAttack: _isAttack),
    );
    if (onLine == null) return by;
    return coordinates.coordinateToScreen(turned(onLine - dot));
  }

  /// How near a line, in screen pixels, a dragged item's dot has to come for
  /// Alt to put it on the line.
  static const double _snapReach = 24;

  Rect get _map => Offset.zero & CoordinateSystem.instance.playAreaSize;

  static Rect _spreadOf(List<Offset> points) {
    var spread = Rect.fromPoints(points.first, points.first);
    for (final point in points.skip(1)) {
      spread = spread.expandToInclude(Rect.fromPoints(point, point));
    }
    return spread;
  }

  /// How far [spread] can go each way, in canvas pixels, staying inside
  /// [area]. What is past that line already can stay there: it only can't go
  /// further out.
  static Rect _roomInside(Rect spread, Rect area) {
    final left = math.min(0.0, area.left - spread.left);
    final top = math.min(0.0, area.top - spread.top);
    return Rect.fromLTRB(
      left,
      top,
      math.max(left, area.right - spread.right),
      math.max(top, area.bottom - spread.bottom),
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
    // Read as soon as the map shows, so the first drag has them.
    ref.watch(
      mapLinesProvider(ref.watch(mapProvider.select((map) => map.currentMap))),
    );
    ref.listen(snapToMapKeyProvider, (_, __) {
      if (_dragOrigin != null) _dragTo(_dragMoved);
    });
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
