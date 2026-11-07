import 'package:flutter/widgets.dart';
import 'package:icarus/const/settings.dart';

/// Hands [builder] its [parent] eased out both ways: [Settings.easeOut]
/// forwards, and [Settings.easeOutReverse] when the parent plays back, so
/// an exit starts moving at once too.
///
/// A widget rather than a CurvedAnimation made in build: one with a reverse
/// curve listens to its parent until it is disposed, and builds don't
/// dispose.
class EasedAnimationBuilder extends StatefulWidget {
  const EasedAnimationBuilder({
    super.key,
    required this.parent,
    required this.builder,
    this.interval,
  });

  final Animation<double> parent;

  /// The part of [parent] to ease over, as [Interval] takes it.
  final (double, double)? interval;

  final Widget Function(BuildContext context, Animation<double> eased) builder;

  @override
  State<EasedAnimationBuilder> createState() => _EasedAnimationBuilderState();
}

class _EasedAnimationBuilderState extends State<EasedAnimationBuilder> {
  late CurvedAnimation _eased = _ease();

  CurvedAnimation _ease() {
    final interval = widget.interval;
    Curve within(Curve curve) => interval == null
        ? curve
        : Interval(interval.$1, interval.$2, curve: curve);
    return CurvedAnimation(
      parent: widget.parent,
      curve: within(Settings.easeOut),
      reverseCurve: within(Settings.easeOutReverse),
    );
  }

  @override
  void didUpdateWidget(EasedAnimationBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.parent != oldWidget.parent ||
        widget.interval != oldWidget.interval) {
      _eased.dispose();
      _eased = _ease();
    }
  }

  @override
  void dispose() {
    _eased.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _eased);
}
