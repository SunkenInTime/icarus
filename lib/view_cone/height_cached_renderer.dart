import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:icarus/view_cone/display_warp.dart';
import 'package:icarus/view_cone/vision_world_projection.dart';

/// Reuses the original 2x shadow image while a cone's exact input is unchanged.
/// Meshes must remain immutable, and meshKey must identify the query result.
/// The caller owns this renderer and disposes it with the painter.
class WorldHeightCachedRenderer {
  WorldHeightCachedRenderer({
    this.maxImages = 64,
    this.maxBytes = 128 * 1024 * 1024,
  }) {
    if (maxImages < 1) throw RangeError.value(maxImages, 'maxImages');
    if (maxBytes < 1) throw RangeError.value(maxBytes, 'maxBytes');
  }

  final int maxImages;

  /// Limits retained RGBA image bytes. An oversized image is drawn once and
  /// released, so export resolution never increases the retained cache budget.
  final int maxBytes;
  final _images = <Object, _CachedShadow>{};
  final _displayMeshes = <(DisplayWarp, Offset, Offset, Offset),
      ({Vertices mesh, double displacement})>{};
  bool _disposed = false;
  int cacheHits = 0;
  int cacheMisses = 0;
  int evictions = 0;
  int disposedImages = 0;

  /// Optional profiling observer after a cone draw. The mesh is immutable.
  void Function(Object coneId, Float32List mesh, Offset nativeOrigin)? onPaint;

  int get residentImages => _images.length;
  int get estimatedRgbaBytes => _images.values
      .fold(0, (bytes, value) => bytes + value.imageSize * value.imageSize * 4);

  /// [scale] is physical pixels per SVG unit: fit scale × zoom × DPR. For an
  /// export use its capture pixel ratio instead of the screen DPR. The canvas
  /// must already carry the corresponding transform. Coordinates and [viewport]
  /// stay in SVG units. Translation alone does not change sample resolution.
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
      DisplayWarp? displayWarp,
      double clearanceMeters = 0,
      double radialFalloff = 0}) {
    if (_disposed) throw StateError('The cached renderer is disposed.');
    if (!scale.isFinite || scale <= 0) {
      throw RangeError.value(scale, 'scale');
    }
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
    var transient = false;
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
      if (replacement.bytes > maxBytes) {
        transient = true;
      } else {
        while (_images.length >= maxImages ||
            estimatedRgbaBytes + replacement.bytes > maxBytes) {
          _disposeImage(_images.remove(_images.keys.first)!);
          evictions++;
        }
      }
      cached = replacement;
      if (!transient) _images[coneId] = cached;
    }
    try {
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
        ..setFloat(22, radialFalloff)
        ..setImageSampler(0, cached.image);
      final bounds =
          Rect.fromCircle(center: origin, radius: cached.canvasRadius);
      final paint = Paint()
        ..shader = shader
        ..isAntiAlias = false;
      if (displayWarp == null) {
        canvas.drawRect(bounds.inflate(1 / scale), paint);
      } else {
        final key = (
          displayWarp,
          projection.origin,
          projection.axisU,
          projection.axisV
        );
        final display = _displayMeshes.putIfAbsent(
            key,
            () => (
                  mesh: displayWarp.createMesh(projection),
                  displacement: displayWarp.displacementBound(projection)
                ));
        canvas.save();
        try {
          canvas.clipRect(
              bounds
                  .inflate(display.displacement + 1 / scale)
                  .intersect(viewport),
              doAntiAlias: false);
          // Mesh texture coordinates are unwarped SVG coordinates. The shader
          // still evaluates source distances, angles and occlusion there.
          canvas.drawVertices(display.mesh, BlendMode.src, paint);
        } finally {
          canvas.restore();
        }
      }
      onPaint?.call(coneId, mesh, projection.toMeters(origin));
    } finally {
      if (transient) _disposeImage(cached);
    }
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
    late final Image image;
    try {
      image = picture.toImageSync(imageSize, imageSize);
    } finally {
      picture.dispose();
    }
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
    for (final mesh in _displayMeshes.values) {
      mesh.mesh.dispose();
    }
    _displayMeshes.clear();
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
  int get bytes => imageSize * imageSize * 4;
}
