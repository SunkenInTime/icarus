import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui';

import 'package:icarus/view_cone/vision_world_projection.dart';

/// Direct-height renderer. Its coordinates are SVG viewBox units.
/// Apply the receiver mask to the completed cones with the compositor.
class WorldHeightRenderer {
  /// [scale] is physical pixels per SVG unit, including fit, zoom and DPR.
  /// The caller applies that transform to the canvas before drawing.
  void paintCone(
      Canvas canvas,
      Float32List mesh,
      VisionWorldProjection projection,
      Offset origin,
      double facing,
      double range,
      double cone,
      double scale,
      Color color,
      ui.FragmentShader shader,
      {double clearanceMeters = 0,
      double radialFalloff = 0}) {
    // Resolve coverage only after shadow union and cone intersection. Applying
    // antialiasing to the cone before opaque triangle subtraction leaves seams
    // when their edges coincide. A 2x mask supplies four coverage samples.
    final canvasRadius = range *
        math.sqrt(math.max(
            projection.axisU.dx * projection.axisU.dx +
                projection.axisV.dx * projection.axisV.dx,
            projection.axisU.dy * projection.axisU.dy +
                projection.axisV.dy * projection.axisV.dy));
    final imageSize = (2 * canvasRadius * scale * 2).ceil() + 8;
    final recorder = ui.PictureRecorder();
    final mask = Canvas(recorder);
    mask.translate(imageSize / 2, imageSize / 2);
    mask.scale(scale * 2);
    mask.transform(Float64List.fromList([
      projection.axisU.dx,
      projection.axisU.dy,
      0,
      0,
      projection.axisV.dx,
      projection.axisV.dy,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1,
    ]));
    final vertices = ui.Vertices.raw(ui.VertexMode.triangles, mesh);
    mask.drawVertices(
        vertices, BlendMode.src, Paint()..color = const Color(0xffffffff));
    vertices.dispose();
    final picture = recorder.endRecording();
    late final Image image;
    try {
      image = picture.toImageSync(imageSize, imageSize);
    } finally {
      picture.dispose();
    }
    shader
      ..setFloat(0, origin.dx)
      ..setFloat(1, origin.dy)
      ..setFloat(2, imageSize / (scale * 2))
      ..setFloat(3, clearanceMeters)
      ..setFloat(4, range)
      ..setFloat(5, color.r)
      ..setFloat(6, color.g)
      ..setFloat(7, color.b)
      ..setFloat(8, color.a)
      ..setFloat(9, 1 / scale)
      ..setFloat(10, imageSize.toDouble())
      ..setFloat(11, math.cos(facing))
      ..setFloat(12, math.sin(facing))
      ..setFloat(13, math.cos(cone / 2))
      ..setFloat(14, projection.vectorToMeters(const Offset(1, 0)).dx)
      ..setFloat(15, projection.vectorToMeters(const Offset(1, 0)).dy)
      ..setFloat(16, projection.vectorToMeters(const Offset(0, 1)).dx)
      ..setFloat(17, projection.vectorToMeters(const Offset(0, 1)).dy)
      ..setFloat(18, projection.axisU.dx)
      ..setFloat(19, projection.axisU.dy)
      ..setFloat(20, projection.axisV.dx)
      ..setFloat(21, projection.axisV.dy)
      ..setFloat(22, radialFalloff)
      ..setImageSampler(0, image);
    final bounds = Rect.fromCircle(center: origin, radius: canvasRadius);
    canvas.drawRect(
        bounds.inflate(1 / scale),
        Paint()
          ..shader = shader
          ..isAntiAlias = false);
    image.dispose();
  }
}
