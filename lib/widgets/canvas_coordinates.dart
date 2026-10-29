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
  /// The canvas whose coordinates everything converts through.
  static CanvasCoordinates? _owner;

  Size? _laidOut;
  bool _onScreen = true;
  bool _onTop = true;
  Size? _reported;

  /// Sets the coordinates to the play area this canvas just laid out, when
  /// they are this canvas's to set. Call it from the canvas's layout, and
  /// nowhere else.
  CoordinateSystem layOutCoordinates(Size playAreaSize) {
    _laidOut = playAreaSize;
    if (!_mayOwn) return CoordinateSystem.instance;
    _owner = this;
    return CoordinateSystem(playAreaSize: playAreaSize);
  }

  /// A canvas off screen never sets the coordinates: one that another route
  /// covers lays out once more as it goes, and sets its own again when it
  /// comes back on screen, which rebuilds it. While a route slides over
  /// another, both canvases are on screen and the one on the top route keeps
  /// them, whichever lays out last. A dialog over a canvas leaves them its.
  bool get _mayOwn {
    if (!_onScreen) return false;
    final owner = _owner;
    return _onTop ||
        owner == null ||
        identical(owner, this) ||
        !owner._onScreen;
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
    // A route under another one stays mounted but off screen.
    _onScreen = TickerMode.valuesOf(context).enabled;
    _onTop = ModalRoute.isCurrentOf(context) ?? true;
  }

  @override
  void dispose() {
    // Not holding a closed canvas, and the replay it shows, in memory.
    if (identical(_owner, this)) _owner = null;
    super.dispose();
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
    // the one on top owns the coordinates.
    final owner = _owner;
    if (owner != null && !identical(owner, this) && owner._onScreen) return;
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
