import 'dart:math' as math;
import 'dart:ui';

/// The offline ground reference subtracted from the source geometry's height.
///
/// Actual navigation heights remain unchanged. An observer on a raised platform
/// therefore keeps that platform's height above this reference.
class TacticalGroundField {
  TacticalGroundField.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 || json['coordinateSpace'] != 'native-meters') {
      throw const FormatException('Unsupported tactical ground field.');
    }
    final rawVertices = json['vertices'];
    final rawTriangles = json['triangles'];
    if (rawVertices is! List ||
        rawTriangles is! List ||
        rawVertices.isEmpty ||
        rawVertices.length % 3 != 0 ||
        rawTriangles.isEmpty ||
        rawTriangles.length % 3 != 0 ||
        rawVertices.length > 3000000 ||
        rawTriangles.length > 6000000) {
      throw const FormatException('Invalid tactical ground field arrays.');
    }
    final values = rawVertices.map((value) {
      if (value is! num || !value.isFinite || value.abs() > 100000) {
        throw const FormatException('Invalid tactical ground coordinate.');
      }
      return value.toDouble();
    }).toList(growable: false);
    final vertexCount = values.length ~/ 3;
    for (final index in rawTriangles) {
      if (index is! int || index < 0 || index >= vertexCount) {
        throw const FormatException('Invalid tactical ground triangle index.');
      }
    }
    for (var i = 0; i < rawTriangles.length; i += 3) {
      final indices = [
        for (var j = 0; j < 3; j++) (rawTriangles[i + j] as int) * 3
      ];
      final points = [
        for (final index in indices) Offset(values[index], values[index + 1])
      ];
      final heights = [for (final index in indices) values[index + 2]];
      final triangle = _GroundTriangle(points, heights);
      if (triangle.determinant.abs() < 1e-12) {
        throw const FormatException('Degenerate tactical ground triangle.');
      }
      final index = _triangles.length;
      _triangles.add(triangle);
      final left = points.map((p) => p.dx).reduce(math.min);
      final right = points.map((p) => p.dx).reduce(math.max);
      final top = points.map((p) => p.dy).reduce(math.min);
      final bottom = points.map((p) => p.dy).reduce(math.max);
      final x0 = (left / _cellSize).floor(), x1 = (right / _cellSize).floor();
      final y0 = (top / _cellSize).floor(), y1 = (bottom / _cellSize).floor();
      if ((x1 - x0 + 1) * (y1 - y0 + 1) > 100000) {
        throw const FormatException('Tactical ground triangle is too large.');
      }
      for (var x = x0; x <= x1; x++) {
        for (var y = y0; y <= y1; y++) {
          (_cells[(x, y)] ??= []).add(index);
        }
      }
    }
  }

  static const _cellSize = 4.0;
  final _triangles = <_GroundTriangle>[];
  final _cells = <(int, int), List<int>>{};

  /// Null means outside the baked field, never permission to choose a new floor.
  double? heightAt(Offset nativePoint) {
    if (!nativePoint.dx.isFinite || !nativePoint.dy.isFinite) return null;
    final candidates = _cells[(
      (nativePoint.dx / _cellSize).floor(),
      (nativePoint.dy / _cellSize).floor()
    )];
    double? result;
    for (final index in candidates ?? const <int>[]) {
      final height = _triangles[index].heightAt(nativePoint);
      if (height == null) continue;
      if (result != null && (result - height).abs() > 1e-5) {
        throw const FormatException(
            'Tactical ground field contains conflicting floors.');
      }
      result = height;
    }
    return result;
  }
}

class _GroundTriangle {
  _GroundTriangle(List<Offset> points, List<double> heights)
      : origin = points[0],
        u = points[1] - points[0],
        v = points[2] - points[0],
        z = heights[0],
        dzU = heights[1] - heights[0],
        dzV = heights[2] - heights[0];
  final Offset origin, u, v;
  final double z, dzU, dzV;
  double get determinant => u.dx * v.dy - u.dy * v.dx;

  double? heightAt(Offset point) {
    final relative = point - origin;
    final a = (relative.dx * v.dy - relative.dy * v.dx) / determinant;
    final b = (u.dx * relative.dy - u.dy * relative.dx) / determinant;
    const tolerance = 1e-9;
    if (a < -tolerance || b < -tolerance || a + b > 1 + tolerance) return null;
    return z + a * dzU + b * dzV;
  }
}
