import 'package:flutter/material.dart';

/// The app's spinner. Material's indicator, turning faster: the speed of the
/// spinner is the speed the wait feels, and Material's reads as sluggish.
class Spinner extends StatefulWidget {
  const Spinner({
    super.key,
    this.size = 14,
    this.strokeWidth = 2,
    this.color,
  });

  final double size;
  final double strokeWidth;

  /// Null takes the theme's primary, as [CircularProgressIndicator] does.
  final Color? color;

  /// How much of Material's cycle a turn of ours takes.
  static const double _cycleScale = 0.6;

  @override
  State<Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<Spinner> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: CircularProgressIndicator.defaultAnimationDuration *
        Spinner._cycleScale,
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: CircularProgressIndicator(
        controller: _controller,
        strokeWidth: widget.strokeWidth,
        color: widget.color,
      ),
    );
  }
}
