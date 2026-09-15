import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/vision_collision.dart';
import 'package:icarus/view_cone/vision_world_index.dart';

import 'package:icarus/view_cone/receiver_compositor.dart';
import 'package:icarus/view_cone/receiver_mask.dart';
import '../tool/world_shadow_mesh.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final receiver = WorldReceiverMask.parse('''
    <svg viewBox="0 0 120 100">
      <path fill="#271406" d="M0 0H30V100H0Z"/>
      <path fill="#271406" d="M80 0H120V100H80Z"/>
      <path fill="#271406" d="M10 10H25V90H10Z"/>
    </svg>
  ''');

  Future<ByteData> render({bool wall = false, bool background = false}) async {
    const origin = Offset(15, 50);
    final mesh = WorldShadowMeshBuilder().build(
      index: VisionWorldIndex([
        if (wall)
          VisionSegment.unthickened(const Offset(55, 0), const Offset(55, 100)),
      ]),
      origin: origin,
      facingAngle: 0,
      coneAngle: math.pi,
      range: 150,
    );
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    if (background) canvas.drawColor(const Color(0xff123456), BlendMode.src);
    paintWorldReceiverVisibility(
      canvas: canvas,
      receiver: receiver,
      paintVisibility: (canvas) {
        canvas.drawRect(
            receiver.viewBox, Paint()..color = const Color(0x8000ff00));
        canvas.save();
        canvas.translate(origin.dx, origin.dy);
        paintWorldShadowMesh(canvas, mesh);
        canvas.restore();
      },
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(120, 100);
    final bytes = (await image.toByteData(format: ImageByteFormat.rawRgba))!;
    picture.dispose();
    image.dispose();
    return bytes;
  }

  int alpha(ByteData bytes, int x, int y) =>
      bytes.getUint8((y * 120 + x) * 4 + 3);

  test('rendered visibility re-enters SVG islands without painting the gap',
      () async {
    final bytes = await render();
    expect(alpha(bytes, 20, 50), 128);
    expect(alpha(bytes, 60, 50), 0);
    expect(alpha(bytes, 100, 50), 128);
    // Overlapping base paths must not compound the cone opacity.
    expect(alpha(bytes, 5, 50), alpha(bytes, 20, 50));
  });

  test('a world wall in an unpainted gap blocks the far SVG island', () async {
    final bytes = await render(wall: true);
    expect(alpha(bytes, 20, 50), 128);
    expect(alpha(bytes, 60, 50), 0);
    expect(alpha(bytes, 100, 50), 0);
  });

  test('clipping the cone leaves existing map paint untouched', () async {
    final bytes = await render(wall: true, background: true);
    for (final x in [60, 100]) {
      final start = (50 * 120 + x) * 4;
      expect(List.generate(4, (i) => bytes.getUint8(start + i)),
          [0x12, 0x34, 0x56, 0xff]);
    }
  });
}
