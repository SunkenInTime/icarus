import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// A right-click menu on [child]. Use this, not [ShadContextMenuRegion].
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
    super.dispose();
  }

  void _onOpenChanged() {
    if (_controller.isOpen) {
      _closeOtherMenu();
      _open = _controller;
    } else if (identical(_open, _controller)) {
      _open = null;
    }
  }

  void _closeOtherMenu() {
    if (!identical(_open, _controller)) _open?.hide();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _closeOtherMenu(),
      child: ShadContextMenuRegion(
        controller: _controller,
        items: widget.items,
        child: widget.child,
      ),
    );
  }
}
