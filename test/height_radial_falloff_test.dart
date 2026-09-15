import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/painting.dart' show RadialGradient, Alignment;
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/height_render.dart';
import 'package:icarus/view_cone/vision_world_projection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('falloff fades visible pixels without changing shadows or cone extent',
      () async {
    final program =
        await FragmentProgram.fromAsset('shaders/world_shadow_radial.frag');
    final renderer = WorldHeightRenderer();
    final projection = VisionWorldProjection(
        origin: Offset.zero,
        axisU: const Offset(2, 0),
        axisV: const Offset(0, 2));
    Future<Uint8List> render(double falloff, Float32List mesh) async {
      final shader = program.fragmentShader();
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      renderer.paintCone(canvas, mesh, projection, const Offset(100, 100), 0,
          40, math.pi / 2, 1, const Color.fromARGB(128, 147, 147, 147), shader,
          radialFalloff: falloff);
      final picture = recorder.endRecording();
      final image = await picture.toImage(200, 200);
      picture.dispose();
      final bytes = (await image.toByteData(format: ImageByteFormat.rawRgba))!
          .buffer
          .asUint8List();
      image.dispose();
      shader.dispose();
      return bytes;
    }

    int alpha(Uint8List bytes, int x, int y) => bytes[(y * 200 + x) * 4 + 3];
    final flat = await render(0, Float32List(0));
    final faded = await render(1, Float32List(0));
    final legacyRecorder = PictureRecorder();
    final legacyCanvas = Canvas(legacyRecorder);
    final legacyBounds =
        Rect.fromCircle(center: const Offset(100, 100), radius: 80);
    legacyCanvas.drawCircle(
        const Offset(100, 100),
        80,
        Paint()
          ..shader = RadialGradient(
            center: Alignment.center,
            radius: 1,
            colors: [
              const Color.fromARGB(255, 147, 147, 147).withValues(alpha: .5),
              const Color(0x00000000)
            ],
            stops: const [0, 1],
          ).createShader(legacyBounds));
    final legacyPicture = legacyRecorder.endRecording();
    final legacyImage = await legacyPicture.toImage(200, 200);
    final legacyBytes =
        (await legacyImage.toByteData(format: ImageByteFormat.rawRgba))!
            .buffer
            .asUint8List();
    legacyPicture.dispose();
    legacyImage.dispose();
    for (final x in [102, 120, 140, 160, 178]) {
      expect(alpha(flat, x, 100), 128);
      final radius = math.sqrt(math.pow(x + .5 - 100, 2) + .25);
      expect(alpha(faded, x, 100), closeTo(128 * (1 - radius / 160), 1));
      for (var channel = 0; channel < 4; channel++) {
        final index = (100 * 200 + x) * 4 + channel;
        expect(faded[index], closeTo(legacyBytes[index], 1),
            reason: 'original app gradient at $x, channel $channel');
      }
    }
    expect(alpha(faded, 102, 100), greaterThan(alpha(faded, 140, 100)));
    expect(alpha(faded, 140, 100), greaterThan(alpha(faded, 178, 100)));
    for (var i = 3; i < flat.length; i += 4) {
      expect(faded[i], lessThanOrEqualTo(flat[i]));
      if (flat[i] == 0) expect(faded[i], 0);
    }
    // Native-coordinate wall shadow starts 20m to the right of the observer.
    final wall = Float32List.fromList(
        [20, -40, 50, -40, 50, 40, 20, -40, 50, 40, 20, 40]);
    final blockedFlat = await render(0, wall),
        blockedFaded = await render(1, wall);
    expect(alpha(blockedFaded, 125, 100), greaterThan(0));
    for (final x in [145, 160, 175]) {
      expect(alpha(blockedFlat, x, 100), 0);
      expect(alpha(blockedFaded, x, 100), 0);
    }
  });
}
