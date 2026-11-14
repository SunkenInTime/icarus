import 'dart:math' as math;
import 'dart:ui';

/// Turns the pointer's positions during one freehand stroke into the
/// stroke's points.
///
/// A mouse reports whole pixels, so the positions of a slow diagonal step
/// sideways one pixel at a time, and a stroke drawn through them is lumpy:
/// plainly so in a small window, or once it is zoomed into or shown on a
/// larger screen. The pen here trails the pointer by [lag] of the pointer's
/// travel, which averages those steps away. The stroke's last point is the
/// pointer itself, so the ink reaches it while drawing and after.
class FreehandPen {
  FreehandPen(
    Offset start, {
    required this.lag,
    required this.spacing,
  })  : _pointer = start,
        _between = start,
        _pen = start,
        _left = [start];

  /// How far behind the pointer the pen trails, in the units of the points.
  final double lag;

  /// The least distance between two points the pen leaves behind.
  final double spacing;

  Offset _pointer;

  /// Follows the pointer; the pen follows this. Two followers in a row
  /// flatten the pixel steps better than one with the same lag.
  Offset _between;
  Offset _pen;

  /// Where the pen has been, [spacing] apart.
  final List<Offset> _left;

  /// Moves the pointer to [pointer] and gives the stroke's points now.
  ///
  /// The pull depends on how far the pointer travelled, not on how often it
  /// reported, so a 1000 Hz mouse and a browser's one report a frame draw
  /// much the same stroke: alike along a straight run, and about a pixel
  /// apart where the hand turns sharply.
  List<Offset> moveTo(Offset pointer) {
    final travelled = (pointer - _pointer).distance;
    final pull = 1 - math.exp(-travelled / (lag / 2));
    _pointer = pointer;
    _between += (pointer - _between) * pull;
    _pen += (_between - _pen) * pull;
    if ((_pen - _left.last).distance >= spacing) _left.add(_pen);
    return points;
  }

  /// Where the pen has been, then the pointer.
  List<Offset> get points {
    if ((_pointer - _left.last).distance >= spacing) {
      return [..._left, _pointer];
    }
    // A pointer that has not left the start is still a click.
    if (_left.length == 1) return [_left.first];
    // The pointer stands in for a point it is nearly on.
    return [..._left.take(_left.length - 1), _pointer];
  }
}
