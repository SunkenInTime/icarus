import 'package:flutter/widgets.dart';
import 'package:icarus/const/coordinate_system.dart';

/// Drag feedback lives in an overlay that keeps the initial feedback widget.
/// Publish its current canonical apex without writing to the saved strategy.
class ViewConeDragOrigin extends ValueNotifier<Offset?> {
  ViewConeDragOrigin() : super(null);

  Offset _screenDelta = Offset.zero;
  Offset _origin = Offset.zero;
  late CoordinateSystem _coordinates;
  double _zoom = 1;
  bool _isAttack = true;

  void start(
      {required Offset origin,
      required CoordinateSystem coordinates,
      required double zoom,
      required bool isAttack}) {
    _screenDelta = Offset.zero;
    _origin = origin;
    _coordinates = coordinates;
    _zoom = zoom;
    _isAttack = isAttack;
    value = origin;
  }

  void update(DragUpdateDetails details) {
    if (value == null) return;
    // Flutter's first accepted update reports the original pointer position
    // with the accumulated threshold delta. Its drag avatar follows delta.
    _screenDelta += details.delta;
    final delta = _screenDelta / _zoom;
    final worldDelta = Offset(_coordinates.screenWidthToWorld(delta.dx),
        _coordinates.screenHeightToWorld(delta.dy));
    value = _origin + worldDelta * (_isAttack ? 1 : -1);
  }

  void end() => value = null;
}
