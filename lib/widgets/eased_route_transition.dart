import 'package:flutter/widgets.dart';
import 'package:icarus/const/settings.dart';

/// A route's fade, with an optional grow from [scaleFrom], on
/// [Settings.easeOut] both ways in and out.
///
/// It holds one [CurvedAnimation] for the route's life: a CurvedAnimation
/// keeps its forward curve when a route is popped mid-entry, so the motion
/// turns around smoothly; a new one built on the way out would jump to the
/// exit curve.
class EasedRouteTransition extends StatefulWidget {
  const EasedRouteTransition({
    super.key,
    required this.animation,
    required this.child,
    this.scaleFrom,
  });

  final Animation<double> animation;
  final Widget child;
  final double? scaleFrom;

  @override
  State<EasedRouteTransition> createState() => _EasedRouteTransitionState();
}

class _EasedRouteTransitionState extends State<EasedRouteTransition> {
  late CurvedAnimation _eased = _ease(widget.animation);

  static CurvedAnimation _ease(Animation<double> parent) => CurvedAnimation(
        parent: parent,
        curve: Settings.easeOut,
        reverseCurve: Settings.easeOut.flipped,
      );

  @override
  void didUpdateWidget(EasedRouteTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _eased.dispose();
      _eased = _ease(widget.animation);
    }
  }

  @override
  void dispose() {
    _eased.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scaleFrom = widget.scaleFrom;
    return FadeTransition(
      opacity: _eased,
      child: scaleFrom == null
          ? widget.child
          : ScaleTransition(
              scale: Tween<double>(begin: scaleFrom, end: 1).animate(_eased),
              child: widget.child,
            ),
    );
  }
}
