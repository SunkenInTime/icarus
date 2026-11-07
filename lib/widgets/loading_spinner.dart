import 'package:flutter/material.dart';

/// The app's indeterminate spinner: Material's arc, turning faster.
///
/// Material's default cycle (a stroke every 1.33 s, a turn every 2.2 s) reads
/// as a slow wait. The same animation at 0.6x the cycle reads as work being
/// done, which makes the wait feel shorter.
class LoadingSpinner extends StatefulWidget {
  const LoadingSpinner({super.key, this.strokeWidth, this.color});

  final double? strokeWidth;
  final Color? color;

  /// One full cycle of the indeterminate animation.
  static final Duration cycle =
      CircularProgressIndicator.defaultAnimationDuration * 0.6;

  @override
  State<LoadingSpinner> createState() => _LoadingSpinnerState();
}

class _LoadingSpinnerState extends State<LoadingSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: LoadingSpinner.cycle,
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CircularProgressIndicator(
      controller: _controller,
      strokeWidth: widget.strokeWidth,
      color: widget.color,
    );
  }
}
