import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';

enum DropInsertionSide {
  before,
  after,
}

/// Resolves which side of a drop target the pointer is on, with a small
/// dead zone around the midpoint so the indicator doesn't flicker back and
/// forth while the pointer hovers near the center.
DropInsertionSide? resolveDropInsertionSide({
  required BuildContext context,
  required Offset globalOffset,
  DropInsertionSide? current,
  double deadZone = 10,
}) {
  final renderObject = context.findRenderObject();
  if (renderObject is! RenderBox || !renderObject.hasSize) return current;

  final dx = renderObject.globalToLocal(globalOffset).dx;
  final midpoint = renderObject.size.width / 2;
  if (current != null && (dx - midpoint).abs() <= deadZone) return current;
  return dx > midpoint ? DropInsertionSide.after : DropInsertionSide.before;
}

/// A stable identity for a single insertion slot in the pinned order.
///
/// The gap between folders A and B is represented as `A|B` whether the
/// indicator is drawn on A's trailing edge or B's leading edge, so a
/// [ValueKey] built from this string keeps the caret from re-animating
/// when the drag handoffs across the gutter between neighbors.
String dropInsertionSlotKey({
  required String itemId,
  required DropInsertionSide side,
  required List<String> pinnedOrder,
}) {
  final index = pinnedOrder.indexOf(itemId);
  if (index == -1) return 'pin-slot:$itemId:${side.name}';

  if (side == DropInsertionSide.before) {
    if (index == 0) return 'pin-slot:start|$itemId';
    return 'pin-slot:${pinnedOrder[index - 1]}|$itemId';
  }

  if (index >= pinnedOrder.length - 1) return 'pin-slot:$itemId|end';
  return 'pin-slot:$itemId|${pinnedOrder[index + 1]}';
}

/// A vertical insertion caret shown while a drag hovers over a reorder
/// target.
///
/// The line is centered inside the layout [gap] between neighboring items,
/// so the indicator drawn on the trailing edge of one item lines up exactly
/// with the one drawn on the leading edge of its neighbor and never jumps
/// as the pointer crosses the gap.
class DropInsertionIndicator extends StatefulWidget {
  const DropInsertionIndicator({
    super.key,
    required this.slotKey,
    required this.side,
    required this.gap,
    this.topInset = 0,
    this.bottomInset = 0,
  });

  /// Stable slot identity; use [dropInsertionSlotKey] to derive this.
  final String slotKey;
  final DropInsertionSide side;

  /// Layout spacing between neighboring items; the line sits at its center.
  final double gap;

  /// Insets that align the caret with the item's visual bounds when the
  /// widget itself fills a larger hit area.
  final double topInset;
  final double bottomInset;

  @override
  State<DropInsertionIndicator> createState() => _DropInsertionIndicatorState();
}

class _DropInsertionIndicatorState extends State<DropInsertionIndicator>
    with SingleTickerProviderStateMixin {
  static final Map<String, int> _slotRefCounts = {};

  static const double _lineWidth = 3;
  static const double _capSize = 7;

  late final AnimationController _controller;
  late final Animation<double> _t;

  @override
  void initState() {
    super.initState();
    final skipEntrance = (_slotRefCounts[widget.slotKey] ?? 0) > 0;
    _slotRefCounts[widget.slotKey] =
        (_slotRefCounts[widget.slotKey] ?? 0) + 1;

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 140),
      value: skipEntrance ? 1 : 0,
    );
    _t = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    if (!skipEntrance) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(covariant DropInsertionIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.slotKey == widget.slotKey) return;

    _releaseSlot(oldWidget.slotKey);

    final skipEntrance = (_slotRefCounts[widget.slotKey] ?? 0) > 0;
    _slotRefCounts[widget.slotKey] =
        (_slotRefCounts[widget.slotKey] ?? 0) + 1;
    _controller.value = skipEntrance ? 1 : 0;
    if (!skipEntrance) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _releaseSlot(widget.slotKey);
    _controller.dispose();
    super.dispose();
  }

  void _releaseSlot(String slotKey) {
    final nextCount = (_slotRefCounts[slotKey] ?? 1) - 1;
    if (nextCount <= 0) {
      _slotRefCounts.remove(slotKey);
    } else {
      _slotRefCounts[slotKey] = nextCount;
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = Settings.tacticalVioletTheme.primary;
    // Lifted well above primary so the caret reads as a bright highlight
    // on the dark workbench instead of another deep violet surface.
    final lineColor = Color.lerp(accent, Colors.white, 0.38)!;
    final glow = BoxShadow(
      color: accent.withValues(alpha: 0.55),
      blurRadius: 7,
      spreadRadius: 1,
    );
    final isBefore = widget.side == DropInsertionSide.before;

    return IgnorePointer(
      child: Padding(
        padding: EdgeInsets.only(
          top: widget.topInset,
          bottom: widget.bottomInset,
        ),
        child: Align(
          alignment: isBefore ? Alignment.centerLeft : Alignment.centerRight,
          child: Transform.translate(
            offset: Offset(
              (widget.gap + _capSize) / 2 * (isBefore ? -1 : 1),
              0,
            ),
            child: AnimatedBuilder(
              animation: _t,
              builder: (context, child) => Opacity(
                opacity: _t.value,
                child: Transform.scale(
                  scaleY: 0.7 + 0.3 * _t.value,
                  child: child,
                ),
              ),
              child: Column(
                children: [
                  _buildCap(lineColor, glow),
                  Expanded(
                    child: Container(
                      width: _lineWidth,
                      decoration: BoxDecoration(
                        color: lineColor,
                        borderRadius: BorderRadius.circular(999),
                        boxShadow: [glow],
                      ),
                    ),
                  ),
                  _buildCap(lineColor, glow),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCap(Color color, BoxShadow glow) {
    return Container(
      width: _capSize,
      height: _capSize,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [glow],
      ),
    );
  }
}
