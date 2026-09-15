import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:icarus/view_cone/vision_world_projection.dart';

/// Reuses the original 2x shadow image while a cone's exact input is unchanged.
/// Meshes must remain immutable, and meshKey must identify the query result.
/// The caller owns this renderer and disposes it with the painter.
class WorldHeightCachedRenderer {
  WorldHeightCachedRenderer({this.maxImages = 10}) {
    if (maxImages < 1 || maxImages > 10) {
      throw RangeError.range(maxImages, 1, 10, 'maxImages');
    }
  }

  final int maxImages;
  final _images = <Object, _CachedShadow>{};
  bool _disposed = false;
  int cacheHits = 0;
  int cacheMisses = 0;
  int evictions = 0;
  int disposedImages = 0;

  int get residentImages => _images.length;
  int get estimatedRgbaBytes => _images.values
      .fold(0, (bytes, value) => bytes + value.imageSize * value.imageSize * 4);

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
      FragmentShader shader,
      {required Object coneId,
      required Object meshKey,
      required Rect viewport,
      double clearanceMeters = 0}) {
    if (_disposed) throw StateError('The cached renderer is disposed.');
    // Keep mesh identity as well as its caller-supplied revision. This prevents
    // a replaced list from inheriting an old image through an unchanged key.
    final state = (
      meshKey,
      mesh,
      projection.origin,
      projection.axisU,
      projection.axisV,
      origin,
      facing,
      range,
      cone,
      scale,
      viewport,
    );
    var cached = _images[coneId];
    if (cached != null && cached.state == state) {
      cacheHits++;
      _images.remove(coneId);
      _images[coneId] = cached;
    } else {
      cacheMisses++;
      // Construct successfully before replacing the old owned image.
      final replacement = _rasterize(mesh, projection, range, scale, state);
      if (cached != null) {
        _images.remove(coneId);
        _disposeImage(cached);
      }
      while (_images.length >= maxImages) {
        _disposeImage(_images.remove(_images.keys.first)!);
        evictions++;
      }
      cached = replacement;
      _images[coneId] = cached;
    }
    final imageSize = cached.imageSize;
    // These uniforms and draw operations intentionally match WorldHeightRenderer.
    // Color and clearance affect this draw, not the cached opaque shadow image.
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
      ..setImageSampler(0, cached.image);
    final bounds = Rect.fromCircle(center: origin, radius: cached.canvasRadius);
    canvas.drawRect(
        bounds.inflate(1 / scale),
        Paint()
          ..shader = shader
          ..isAntiAlias = false);
  }

  _CachedShadow _rasterize(Float32List mesh, VisionWorldProjection projection,
      double range, double scale, Object state) {
    final canvasRadius = range *
        math.sqrt(math.max(
            projection.axisU.dx * projection.axisU.dx +
                projection.axisV.dx * projection.axisV.dx,
            projection.axisU.dy * projection.axisU.dy +
                projection.axisV.dy * projection.axisV.dy));
    final imageSize = (2 * canvasRadius * scale * 2).ceil() + 8;
    final recorder = PictureRecorder();
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
    final vertices = Vertices.raw(VertexMode.triangles, mesh);
    mask.drawVertices(
        vertices, BlendMode.src, Paint()..color = const Color(0xffffffff));
    vertices.dispose();
    final picture = recorder.endRecording();
    final image = picture.toImageSync(imageSize, imageSize);
    picture.dispose();
    return _CachedShadow(state, image, imageSize, canvasRadius);
  }

  void removeCone(Object coneId) {
    final value = _images.remove(coneId);
    if (value != null) _disposeImage(value);
  }

  void clear() {
    for (final value in _images.values) {
      _disposeImage(value);
    }
    _images.clear();
  }

  void _disposeImage(_CachedShadow value) {
    value.image.dispose();
    disposedImages++;
  }

  void dispose() {
    if (_disposed) return;
    clear();
    _disposed = true;
  }
}

class _CachedShadow {
  const _CachedShadow(
      this.state, this.image, this.imageSize, this.canvasRadius);
  final Object state;
  final Image image;
  final int imageSize;
  final double canvasRadius;
}
