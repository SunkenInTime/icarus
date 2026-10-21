import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';

FreeDrawing _dot() => FreeDrawing(
      id: 'dot',
      listOfPoints: [const Offset(900, 500)],
      color: Colors.white,
      thickness: 8,
      isDotted: false,
      hasArrow: false,
    );

void main() {
  test('a one-point drawing builds on a map under 415 px tall without throwing', () {
    final coordinateSystem =
        CoordinateSystem(playAreaSize: const Size(700, 400));
    final dot = _dot()..rebuildPath(coordinateSystem);
    // A radius of at least a pixel, however short the map.
    expect(dot.path.getBounds().width, 2);
  });

  test('a one-point drawing keeps its size on a taller map', () {
    final coordinateSystem =
        CoordinateSystem(playAreaSize: const Size(1662, 831));
    final dot = _dot()..rebuildPath(coordinateSystem);
    expect(dot.path.getBounds().width, 4);
  });
}
