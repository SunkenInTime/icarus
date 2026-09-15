import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// Checks whether a fixed display mesh can remap the existing visibility shader
/// while leaving its range, angle and mask calculations in source coordinates.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('visibility shader receives source coordinates from display mesh',
      () async {
    final program =
        await ui.FragmentProgram.fromAsset('shaders/world_shadow_radial.frag');
    final shader = program.fragmentShader();
    final emptyRecorder = ui.PictureRecorder();
    ui.Canvas(emptyRecorder);
    final emptyPicture = emptyRecorder.endRecording();
    final emptyMask = emptyPicture.toImageSync(32, 32);
    emptyPicture.dispose();
    final values = <double>[
      20, 20, // Source origin.
      100, 0, 5, // Mask span, clearance, source range.
      1, 0, 0, 1, // Red.
      1, 32, // Pixel footprint and mask resolution.
      1, 0, -1, // Full-circle direction test.
      1, 0, 0, 1, // Canvas to metres.
      1, 0, 0, 1, // Metres to canvas.
      0, // No radial fade.
    ];
    for (var i = 0; i < values.length; i++) {
      shader.setFloat(i, values[i]);
    }
    shader.setImageSampler(0, emptyMask);
    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      Float32List.fromList([30, 0, 130, 0, 130, 100, 30, 100]),
      textureCoordinates:
          Float32List.fromList([0, 0, 100, 0, 100, 100, 0, 100]),
      indices: Uint16List.fromList([0, 1, 2, 0, 2, 3]),
    );
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawVertices(
        vertices, ui.BlendMode.src, ui.Paint()..shader = shader);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(140, 110);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    int alpha(int x, int y) => bytes.getUint8((y * 140 + x) * 4 + 3);
    try {
      expect(alpha(50, 20), 255,
          reason: 'Source circle centre must move through the display mesh.');
      expect(alpha(20, 20), 0);
      expect(alpha(57, 20), 0,
          reason: 'The five-metre range stays in source coordinates.');
    } finally {
      image.dispose();
      picture.dispose();
      vertices.dispose();
      shader.dispose();
      emptyMask.dispose();
    }
  });
}
