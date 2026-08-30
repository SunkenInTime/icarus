import 'package:flutter/material.dart';

/// Fades a shape edit handle in and out with hover, and makes it
/// untouchable while hidden so it never blocks whatever is underneath.
class ShapeIndicatorFade extends StatelessWidget {
  const ShapeIndicatorFade({
    super.key,
    required this.visible,
    required this.child,
  });

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        child: child,
      ),
    );
  }
}
