import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Lets hits inside a circle fall through to whatever is underneath. A
/// custom circle's resize handle is a square around its diagonal arc, which
/// on a small circle overlaps the center marker; a hole over the marker
/// hands those hits back to it, so the circle still moves.
class MarkerHitHole extends SingleChildRenderObjectWidget {
  const MarkerHitHole({
    super.key,
    required this.center,
    required this.radius,
    super.child,
  });

  /// In this widget's own coordinates.
  final Offset center;
  final double radius;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderMarkerHitHole(center: center, radius: radius);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderMarkerHitHole renderObject,
  ) {
    renderObject
      ..center = center
      ..radius = radius;
  }
}

class RenderMarkerHitHole extends RenderProxyBox {
  RenderMarkerHitHole({required this.center, required this.radius});

  Offset center;
  double radius;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if ((position - center).distance < radius) return false;
    return super.hitTest(result, position: position);
  }
}
