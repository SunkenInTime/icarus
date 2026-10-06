import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/widgets/dot_painter.dart';

// Its own file: the shader loads on the real event loop.
void main() {
  Future<Uint8List> paint(WidgetTester tester, DotPainter painter, Size size) =>
      tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        painter.paint(Canvas(recorder), size);
        final image = await recorder
            .endRecording()
            .toImage(size.width.toInt(), size.height.toInt());
        final bytes = await image.toByteData();
        return bytes!.buffer.asUint8List();
      }).then((bytes) => bytes!);

  testWidgets('the web grid shader draws the dots the points do',
      (tester) async {
    final program = await tester.runAsync(
        () => ui.FragmentProgram.fromAsset('shaders/dot_lattice.frag'));
    final shader = program!.fragmentShader();
    addTearDown(shader.dispose);
    // Sizes whose spacing stretches by different amounts on each axis.
    for (final size in const [Size(300, 200), Size(257, 133)]) {
      final points = await paint(tester, DotPainter(opacity: 1), size);
      final lattice =
          await paint(tester, DotPainter(opacity: 1, shader: shader), size);
      final width = size.width.toInt(), height = size.height.toInt();
      var worst = 0, ink = 0, latticeInk = 0;
      // Away from the edges: rounding can drop the points' last row or
      // column, which the shader always draws.
      for (var y = 4; y < height - 4; y++) {
        for (var x = 4; x < width - 4; x++) {
          final i = (y * width + x) * 4;
          for (var c = 0; c < 4; c++) {
            final gap = (points[i + c] - lattice[i + c]).abs();
            if (gap > worst) worst = gap;
          }
          ink += points[i + 3];
          latticeInk += lattice[i + 3];
        }
      }
      // The same dots in the same places, antialiased a little differently.
      expect(worst, lessThanOrEqualTo(48), reason: '$size');
      expect(latticeInk / ink, inInclusiveRange(0.92, 1.1), reason: '$size');
    }
  });
}
