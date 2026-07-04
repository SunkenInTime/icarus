import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Feeds pointer movement from a [Draggable.onDragUpdate] callback into the
/// drag preview so it can react to the drag direction.
///
/// The owning widget keeps one controller and calls [addDelta] on every drag
/// update; the [TiltDragFeedback] ticker drains it once per frame.
class DragTiltController {
  double _pendingDx = 0;

  void addDelta(double dx) => _pendingDx += dx;

  double takePendingDx() {
    final dx = _pendingDx;
    _pendingDx = 0;
    return dx;
  }
}

/// Shared drag-preview wrapper for library items (strategy tiles, folder
/// cards, folder pills).
///
/// Makes the drag feel physical in two ways:
/// - The preview hangs from the pointer by its top-center edge (the pointer
///   is the grip point) instead of sitting at its top-left corner.
/// - It swings a few degrees away from the direction of travel, pivoting
///   around the grip point, and settles back with an exponential ease when
///   movement stops. No bounce, no overshoot.
class TiltDragFeedback extends StatefulWidget {
  const TiltDragFeedback({
    super.key,
    required this.controller,
    required this.child,
    this.opacity = 0.95,
  });

  final DragTiltController controller;
  final Widget child;
  final double opacity;

  @override
  State<TiltDragFeedback> createState() => _TiltDragFeedbackState();
}

class _TiltDragFeedbackState extends State<TiltDragFeedback>
    with SingleTickerProviderStateMixin {
  // ~3.4 degrees: readable as physical swing without looking cartoonish.
  static const double _maxTilt = 0.06;
  static const double _velocityToTilt = 0.0001;
  static const double _baselineFrameSeconds = 1 / 60;

  late final Ticker _ticker;
  double _velocity = 0;
  double _angle = 0;
  Duration? _lastElapsed;

  @override
  void initState() {
    super.initState();
    // Discard movement buffered before this drag's preview mounted.
    widget.controller.takePendingDx();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final previousElapsed = _lastElapsed;
    _lastElapsed = elapsed;

    final rawDt = previousElapsed == null
        ? _baselineFrameSeconds
        : (elapsed - previousElapsed).inMicroseconds /
            Duration.microsecondsPerSecond;
    final dt = rawDt.clamp(1 / 240, 1 / 15).toDouble();
    final frameScale = dt / _baselineFrameSeconds;

    // Low-pass pointer velocity, then chase the tilt target. Converting the
    // 60 Hz tuning constants to wall-time keeps the feel stable across refresh
    // rates while preserving the original baseline.
    final velocityAlpha = 1 - math.pow(0.78, frameScale).toDouble();
    final angleAlpha = 1 - math.pow(0.76, frameScale).toDouble();
    final movementVelocity = widget.controller.takePendingDx() / dt;

    _velocity += (movementVelocity - _velocity) * velocityAlpha;
    final target = (_velocity * _velocityToTilt).clamp(-_maxTilt, _maxTilt);
    final next = _angle + (target - _angle) * angleAlpha;

    if ((next - _angle).abs() < 0.0002 && target.abs() < 0.0002) {
      if (_angle != 0) setState(() => _angle = 0);
      return;
    }
    setState(() => _angle = next);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    Widget preview = Material(
      color: Colors.transparent,
      child: widget.child,
    );

    if (!reduceMotion) {
      preview = Transform.rotate(
        angle: _angle,
        alignment: Alignment.topCenter,
        child: preview,
      );
    }

    // The Draggable pins the feedback's top-left to the pointer
    // (pointerDragAnchorStrategy); shifting by half the preview's own width
    // moves the grip point to top-center regardless of preview size.
    return IgnorePointer(
      child: Opacity(
        opacity: widget.opacity,
        child: FractionalTranslation(
          translation: const Offset(-0.5, 0),
          child: preview,
        ),
      ),
    );
  }
}
