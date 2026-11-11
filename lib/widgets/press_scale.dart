import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:icarus/const/settings.dart';

/// Shrinks [child] a little while it is held down, so a button answers the
/// moment it is pressed (DESIGN.md, Motion).
///
/// The press starts on pointer down and listens to raw pointer events, so it
/// never joins the gesture arena: it can't delay the click or take a
/// right-click from a [RightClickDetector]. Only the primary button presses.
///
/// Every [ShadButton] already gets one from the [ShadButtonWrapper] in
/// main.dart. Use this directly only for buttons that aren't Shad's.
class PressScale extends StatefulWidget {
  const PressScale({
    super.key,
    this.enabled = true,
    required this.child,
  });

  /// False while the button is disabled: a disabled button doesn't press.
  final bool enabled;
  final Widget child;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  /// Each pointer holding the button down, to the device that pressed it.
  final Map<int, int> _pointers = {};

  bool get _pressed => _pointers.isNotEmpty;

  @override
  void didUpdateWidget(PressScale oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A button that turns disabled while held (a save that starts on click)
    // lets go at once.
    if (!widget.enabled) _pointers.clear();
  }

  void _down(PointerDownEvent event) {
    if (!widget.enabled || event.buttons & kPrimaryButton == 0) return;
    setState(() => _pointers[event.pointer] = event.device);
  }

  void _release(PointerEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    setState(() => _pointers.remove(event.pointer));
  }

  /// A hovering device has no buttons down. If its release was lost (the
  /// window lost focus mid-press), let go now instead of staying shrunk.
  void _releaseDevice(PointerHoverEvent event) {
    if (!_pointers.containsValue(event.device)) return;
    setState(() => _pointers.removeWhere((_, d) => d == event.device));
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _down,
      onPointerUp: _release,
      onPointerCancel: _release,
      onPointerHover: _releaseDevice,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: _pressed ? 1 : 0),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : Settings.pressDuration,
        curve: Settings.easeOut,
        builder: (context, amount, child) =>
            _PressedBox(amount: amount, child: child),
        child: widget.child,
      ),
    );
  }
}

/// Paints its child scaled about its center by [amount] of a press, 0 at
/// rest and 1 fully pressed. Layout and hit testing keep the full size, so
/// the button doesn't shrink out from under the pointer.
class _PressedBox extends SingleChildRenderObjectWidget {
  const _PressedBox({required this.amount, super.child});

  final double amount;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPressedBox(amount);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPressedBox renderObject,
  ) {
    renderObject.amount = amount;
  }
}

class _RenderPressedBox extends RenderProxyBox {
  _RenderPressedBox(this._amount);

  double _amount;
  set amount(double value) {
    if (value == _amount) return;
    _amount = value;
    markNeedsPaint();
  }

  /// The share of its size a fully pressed box loses: [Settings.pressScale]
  /// for a button, less once its edges would move past
  /// [Settings.pressMaxInset].
  double get _shrink {
    final longest = size.longestSide;
    if (longest == 0) return 0;
    return math.min(
      1 - Settings.pressScale,
      2 * Settings.pressMaxInset / longest,
    );
  }

  Matrix4 get _transform {
    final scale = 1 - _amount * _shrink;
    final center = size.center(Offset.zero);
    return Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    if (_amount == 0) {
      layer = null;
      context.paintChild(child!, offset);
      return;
    }
    layer = context.pushTransform(
      needsCompositing,
      offset,
      _transform,
      (context, offset) => context.paintChild(child!, offset),
      oldLayer: layer is TransformLayer ? layer as TransformLayer : null,
    );
  }

  // Where the child is drawn, for anything that asks (a tooltip, a test);
  // hit testing keeps the full size.
  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    if (_amount != 0) transform.multiply(_transform);
  }
}
