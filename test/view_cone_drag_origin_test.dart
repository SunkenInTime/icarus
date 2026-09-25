import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/widgets/draggable_widgets/view_cone_drag_origin.dart';

void main() {
  test(
      'drag apex follows screen displacement across side, zoom and aspect ratio',
      () {
    for (final size in [
      const Size(1920, 1080),
      const Size(1600, 900),
      const Size(1200, 900)
    ]) {
      final coordinates = CoordinateSystem(playAreaSize: size);
      for (final attack in [true, false]) {
        for (final zoom in [1.0, 2.5, 8.0]) {
          final origin = ViewConeDragOrigin();
          const start = Offset(712, 430),
              pointer = Offset(500, 400),
              move = Offset(71, -43);
          origin.start(
              origin: start,
              coordinates: coordinates,
              zoom: zoom,
              isAttack: attack);
          origin
              .update(DragUpdateDetails(globalPosition: pointer, delta: move));
          Offset display(Offset canonical) =>
              coordinates.coordinateToScreen(coordinates.positionForSide(
                  canonicalPosition: canonical,
                  reflectionOffset: Offset.zero,
                  isAttack: attack)) *
              zoom;
          final displacement = display(origin.value!) - display(start);
          expect(displacement.dx, closeTo(move.dx, 1e-9));
          expect(displacement.dy, closeTo(move.dy, 1e-9));
          origin.end();
          origin.update(DragUpdateDetails(globalPosition: Offset.zero));
          expect(origin.value, isNull);
          origin.dispose();
        }
      }
    }
  });
}
