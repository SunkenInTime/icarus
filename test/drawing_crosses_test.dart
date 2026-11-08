import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/providers/drawing_provider.dart';

Line _line(Offset from, Offset to, {bool arrow = false}) => Line(
      lineStart: from,
      lineEnd: to,
      color: Colors.white,
      isDotted: false,
      hasArrow: arrow,
      id: 'line',
    );

FreeDrawing _free(List<Offset> points) => FreeDrawing(
      listOfPoints: points,
      color: Colors.white,
      isDotted: false,
      hasArrow: false,
      id: 'free',
    )..rebuildPath(CoordinateSystem.instance);

/// Where [point], in world coordinates, is painted.
Offset _drawn(Offset point) =>
    CoordinateSystem.instance.coordinateToScreen(point);

/// A box over the world rectangle from (left, top) to (right, bottom), as
/// painted.
Rect _box(double left, double top, double right, double bottom) =>
    Rect.fromPoints(
      _drawn(Offset(left, top)),
      _drawn(Offset(right, bottom)),
    );

void main() {
  setUpAll(() => CoordinateSystem(playAreaSize: const Size(1778, 1000)));

  group('a selection box takes a drawing only where it crosses the stroke', () {
    final diagonal = _line(Offset.zero, const Offset(100, 100));

    test('a box across a diagonal line takes it', () {
      expect(drawingCrosses(diagonal, _box(40, 55, 70, 80)), isTrue);
    });

    test("a box in a diagonal line's bounding box but off it misses", () {
      expect(drawingCrosses(diagonal, _box(60, 10, 90, 30)), isFalse);
    });

    test('a box around one end of a line takes it', () {
      expect(drawingCrosses(diagonal, _box(90, 90, 120, 120)), isTrue);
    });

    test('a box over only an arrowhead takes the line', () {
      const shaft = (from: Offset(0, 50), to: Offset(100, 50));
      final head = _drawn(shaft.to);
      // Above the shaft, on the arrowhead's upper stroke.
      final box =
          Rect.fromLTRB(head.dx - 5, head.dy - 5, head.dx - 3, head.dy - 3);

      expect(
        drawingCrosses(_line(shaft.from, shaft.to, arrow: true), box),
        isTrue,
      );
      expect(drawingCrosses(_line(shaft.from, shaft.to), box), isFalse);
    });

    test('a freehand stroke is taken where it is painted, smoothed', () {
      final bend =
          _free(const [Offset(0, 0), Offset(100, 0), Offset(100, 100)]);

      // The painted curve rounds the corner through (87.5, 12.5).
      expect(drawingCrosses(bend, _box(85, 10, 90, 15)), isTrue);
      // The stored corner point, which the curve stays well clear of.
      expect(drawingCrosses(bend, _box(97, 0, 100, 3)), isFalse);
    });

    test('a box crossing a freehand stroke between its points takes it', () {
      final stroke = _free(
        const [Offset(0, 50), Offset(100, 50), Offset(100, 0)],
      );

      expect(drawingCrosses(stroke, _box(40, 40, 60, 60)), isTrue);
      expect(drawingCrosses(stroke, _box(40, 0, 60, 30)), isFalse);
    });

    test('a freehand stroke of one point is painted as nothing', () {
      expect(
        drawingCrosses(_free(const [Offset(50, 50)]), _box(40, 40, 60, 60)),
        isFalse,
      );
    });

    test('a box inside a drawn rectangle or ellipse misses it', () {
      final rectangle = RectangleDrawing(
        start: Offset.zero,
        end: const Offset(100, 100),
        color: Colors.white,
        isDotted: false,
        hasArrow: false,
        id: 'rectangle',
      );
      final ellipse = EllipseDrawing(
        start: Offset.zero,
        end: const Offset(100, 100),
        color: Colors.white,
        isDotted: false,
        hasArrow: false,
        id: 'ellipse',
      );
      final inside = _box(40, 40, 60, 60);
      final acrossTheEdge = _box(-10, 40, 10, 60);

      expect(drawingCrosses(rectangle, inside), isFalse);
      expect(drawingCrosses(ellipse, inside), isFalse);
      expect(drawingCrosses(rectangle, acrossTheEdge), isTrue);
      expect(drawingCrosses(ellipse, acrossTheEdge), isTrue);
      // The rectangle's corner is outside the ellipse.
      expect(drawingCrosses(ellipse, _box(0, 0, 5, 5)), isFalse);
    });
  });
}
