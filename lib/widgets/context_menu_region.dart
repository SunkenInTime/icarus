import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// A right-click menu on [child]. Use this, not [ShadContextMenuRegion].
///
/// A right-click or long press opens the menu with its top-left corner at the
/// pointer, like a desktop menu ([ContextMenuAtPoint]). shadcn_ui's region
/// centers it on the pointer instead. A menu opened through [controller],
/// like one a button opens, still opens below [child].
///
/// shadcn_ui puts every context menu and every region that opens one in a
/// single tap group, so a press on another region isn't a press outside the
/// open menu and leaves it open. This closes it, so one menu shows at a time.
class ContextMenuRegion extends StatefulWidget {
  const ContextMenuRegion({
    super.key,
    required this.items,
    required this.child,
    this.controller,
  });

  final List<Widget> items;
  final Widget child;

  /// For a menu something else opens too, like a button on [child].
  final ShadContextMenuController? controller;

  @override
  State<ContextMenuRegion> createState() => _ContextMenuRegionState();
}

class _ContextMenuRegionState extends State<ContextMenuRegion> {
  static ShadContextMenuController? _open;

  final _ownController = ShadContextMenuController();

  /// Never opens. Of the menu below [child] and the menu at the pointer,
  /// the one not showing holds this, so the controller opens only one.
  final _idle = ShadContextMenuController();

  final _pointerLayer = OverlayPortalController();

  /// Where the menu opens, in global coordinates, while it opens at the
  /// pointer.
  Offset? _pointer;

  Offset? _longPressAt;

  final _browserMenuWasOff = kIsWeb && !BrowserContextMenu.enabled;

  ShadContextMenuController get _controller =>
      widget.controller ?? _ownController;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onOpenChanged);
  }

  @override
  void didUpdateWidget(covariant ContextMenuRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.controller ?? _ownController;
    if (identical(previous, _controller)) return;
    previous.removeListener(_onOpenChanged);
    if (identical(_open, previous)) _open = null;
    _controller.addListener(_onOpenChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onOpenChanged);
    if (identical(_open, _controller)) _open = null;
    _ownController.dispose();
    _idle.dispose();
    super.dispose();
  }

  void _onOpenChanged() {
    if (_controller.isOpen) {
      _closeOtherMenu();
      _open = _controller;
      return;
    }
    if (identical(_open, _controller)) _open = null;
    if (_pointer != null) {
      setState(() => _pointer = null);
      _pointerLayer.hide();
    }
  }

  void _closeOtherMenu() {
    if (!identical(_open, _controller)) _open?.hide();
  }

  void _openAt(Offset pointer) {
    // Frees the controller from a menu already showing, below [child] or at
    // an earlier point.
    _controller.hide();
    setState(() => _pointer = pointer);
    _pointerLayer.show();
    // The menu below [child] lets go of the controller in the next build.
    // Opening before then would open it too.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pointer == pointer) _controller.show();
    });
  }

  @override
  Widget build(BuildContext context) {
    final pointer = _pointer;
    final longPress = defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    // Windows opens a context menu when the button comes up.
    final onButtonUp = defaultTargetPlatform == TargetPlatform.windows;

    return Listener(
      onPointerDown: (_) => _closeOtherMenu(),
      child: OverlayPortal(
        controller: _pointerLayer,
        overlayChildBuilder: (_) => Positioned.fill(
          child: ContextMenuAtPoint(
            controller: pointer == null ? _idle : _controller,
            position: pointer ?? Offset.zero,
            items: widget.items,
          ),
        ),
        child: ShadContextMenu(
          controller: pointer == null ? _controller : _idle,
          items: widget.items,
          child: ShadGestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => _controller.hide(),
            onSecondaryTapDown: (details) async {
              if (kIsWeb && !_browserMenuWasOff) {
                await BrowserContextMenu.disableContextMenu();
              }
              if (!onButtonUp) _openAt(details.globalPosition);
            },
            onSecondaryTapUp: (details) async {
              if (onButtonUp) _openAt(details.globalPosition);
              if (kIsWeb && !_browserMenuWasOff) {
                await Future<void>.delayed(Duration.zero);
                await BrowserContextMenu.enableContextMenu();
              }
            },
            onLongPressStart: longPress
                ? (details) => _longPressAt = details.globalPosition
                : null,
            onLongPress: longPress ? () => _openAt(_longPressAt!) : null,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// A context menu with its top-left corner at [position], a point in global
/// coordinates, the way desktop menus open. Near the bottom of the window it
/// opens upward from the point, and near the right edge it moves left until
/// it fits.
///
/// It fills the [Overlay] it's in, so build it where that's the whole
/// overlay: in an [OverlayPortal]'s overlay child or as a route's page.
class ContextMenuAtPoint extends StatelessWidget {
  const ContextMenuAtPoint({
    super.key,
    required this.controller,
    required this.position,
    required this.items,
  });

  final ShadContextMenuController controller;
  final Offset position;
  final List<Widget> items;

  @override
  Widget build(BuildContext context) {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    return ShadContextMenu(
      controller: controller,
      // shadcn_ui centers a menu on the point it's given, below the point or
      // above when it doesn't fit below, then moves it sideways into the
      // window. Measured from the bottom right, the point it's given is half
      // the menu's width right of [position], so its left edge lands there.
      anchor: ShadAnchorAuto(
        targetAnchor: Alignment.topLeft,
        followerAnchor: Alignment.bottomRight,
        offset: overlay.globalToLocal(position),
      ),
      items: items,
      child: const SizedBox.expand(),
    );
  }
}
