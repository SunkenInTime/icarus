import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:icarus/const/coordinate_system.dart';

/// For a canvas: the editor's map, the replay's. It sets the coordinates
/// that every item, lineup line and stroke on it converts through, and in
/// debug builds it checks after each frame, while it is on screen, that
/// nothing else has replaced them.
///
/// Anything that replaces them, even a screen hidden under the editor,
/// moves whatever redraws next and nothing else, so on screen it looks like
/// items drifting at random (#405).
mixin CanvasCoordinates<T extends StatefulWidget> on State<T> {
  /// The canvas that set the coordinates last.
  static CanvasCoordinates? _owner;

  Size? _laidOut;
  bool _onScreen = true;
  Size? _reported;

  /// Sets the coordinates to the play area this canvas just laid out.
  /// Call it from the canvas's layout, and nowhere else.
  CoordinateSystem layOutCoordinates(Size playAreaSize) {
    _laidOut = playAreaSize;
    // A canvas lays out once more as another route covers it; the canvas on
    // screen keeps the coordinates. This one sets its own again when it
    // comes back on screen, which rebuilds it.
    if (!_onScreen) return CoordinateSystem.instance;
    _owner = this;
    return CoordinateSystem(playAreaSize: playAreaSize);
  }

  @override
  void initState() {
    super.initState();
    assert(() {
      _checkAfterNextFrame();
      return true;
    }());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A route under another one stays mounted but off screen; whichever
    // canvas is on screen owns the coordinates then.
    _onScreen = TickerMode.valuesOf(context).enabled;
  }

  void _checkAfterNextFrame() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _check();
      _checkAfterNextFrame();
    });
  }

  void _check() {
    final laidOut = _laidOut;
    if (laidOut == null || !_onScreen) return;
    // While a route slides over another, both canvases are on screen and
    // the newer one owns the coordinates.
    final owner = _owner;
    if (owner != this && owner != null && owner.mounted && owner._onScreen) {
      return;
    }
    final current = CoordinateSystem.instance.playAreaSize;
    if (current == laidOut) {
      _reported = null;
      return;
    }
    if (current == _reported) return;
    _reported = current;
    FlutterError.reportError(FlutterErrorDetails(
      exception: FlutterError.fromParts([
        ErrorSummary('Something replaced the canvas coordinates.'),
        ErrorDescription(
          '$T laid out a play area of ${_size(laidOut)}, but the coordinates '
          'are now ${_size(current)}. Everything redrawn from here lands in '
          'the wrong place.',
        ),
        ErrorHint(
          'Only a canvas on screen sets the coordinates, through '
          'layOutCoordinates. A screen without a canvas must not construct '
          'CoordinateSystem.',
        ),
      ]),
      library: 'icarus canvas',
    ));
  }

  static String _size(Size size) =>
      '${size.width.toStringAsFixed(1)}×${size.height.toStringAsFixed(1)}';
}
