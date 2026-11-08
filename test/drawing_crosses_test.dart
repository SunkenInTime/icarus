import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/providers/drawing_provider.dart';

Line _line(Offset from, Offset to) => Line(
      lineStart: from,
      lineEnd: to,
      color: Colors.white,
      isDotted: false,
      hasArrow: true,
      id: 'line',
    );

void main() {
  group('a selection box takes a drawing only where it crosses the stroke', () {
    final diagonal = _line(Offset.zero, const Offset(100, 100));

    test('a box across a diagonal line takes it', () {
      expect(
        drawingCrosses(diagonal, const Rect.fromLTRB(40, 55, 70, 80)),
        isTrue,
      );
    });

    test("a box in a diagonal line's bounding box but off it misses", () {
      expect(
        drawingCrosses(diagonal, const Rect.fromLTRB(60, 10, 90, 30)),
        isFalse,
      );
    });

    test('a box around one end of a line takes it', () {
      expect(
        drawingCrosses(diagonal, const Rect.fromLTRB(90, 90, 120, 120)),
        isTrue,
      );
    });

    test('a box crossing a freehand stroke between its points takes it', () {
      final stroke = FreeDrawing(
        listOfPoints: const [Offset(0, 50), Offset(100, 50), Offset(100, 0)],
        color: Colors.white,
        isDotted: false,
        hasArrow: false,
        id: 'free',
      );

      expect(
        drawingCrosses(stroke, const Rect.fromLTRB(40, 40, 60, 60)),
        isTrue,
      );
      expect(
        drawingCrosses(stroke, const Rect.fromLTRB(40, 0, 60, 30)),
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
      const inside = Rect.fromLTRB(40, 40, 60, 60);
      const acrossTheEdge = Rect.fromLTRB(-10, 40, 10, 60);

      expect(drawingCrosses(rectangle, inside), isFalse);
      expect(drawingCrosses(ellipse, inside), isFalse);
      expect(drawingCrosses(rectangle, acrossTheEdge), isTrue);
      expect(drawingCrosses(ellipse, acrossTheEdge), isTrue);
      // The rectangle's corner is outside the ellipse.
      expect(
        drawingCrosses(ellipse, const Rect.fromLTRB(0, 0, 5, 5)),
        isFalse,
      );
    });
  });
}
