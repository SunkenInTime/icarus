import 'dart:math' as math;
import 'dart:ui';

/// Baked primary ground. Its triangles supply heights, never collision edges.
/// Separate raised surfaces remain explicit support choices in the map model.
class SvgGroundHeight {
  SvgGroundHeight.fromJson(Map<String, dynamic> json) {
    final rawVertices = json['vertices'];
    final rawTriangles = json['triangles'];
    if (rawVertices is! List ||
        rawVertices.length % 3 != 0 ||
        rawTriangles is! List ||
        rawTriangles.length % 3 != 0) {
      throw const FormatException('Invalid ground arrays.');
    }
    final rawStanding = json['standingTriangles'];
    if (rawStanding != null &&
        (rawStanding is! List ||
            rawStanding.any(
                (v) => v is! int || v < 0 || v >= rawTriangles.length ~/ 3))) {
      throw const FormatException('Invalid physical ground triangle indices.');
    }
    final standing = (rawStanding as List? ?? []).cast<int>().toSet();
    if (rawStanding is List && standing.length != rawStanding.length) {
      throw const FormatException('Duplicate physical ground triangle index.');
    }
    final vertices = <(Offset, double)>[];
    for (var i = 0; i < rawVertices.length; i += 3) {
      final values = rawVertices.sublist(i, i + 3);
      if (values.any((v) => v is! num || !v.isFinite)) {
        throw const FormatException('Invalid ground vertex.');
      }
      vertices.add((
        Offset((values[0] as num).toDouble(), (values[1] as num).toDouble()),
        (values[2] as num).toDouble()
      ));
    }
    this.vertices = List.unmodifiable(vertices);
    for (var i = 0; i < rawTriangles.length; i += 3) {
      final indices = rawTriangles.sublist(i, i + 3);
      if (indices.any((v) => v is! int || v < 0 || v >= vertices.length)) {
        throw const FormatException('Invalid ground triangle.');
      }
      final a = vertices[indices[0]],
          b = vertices[indices[1]],
          c = vertices[indices[2]];
      final triangle = _GroundTriangle(a, b, c, standing.contains(i ~/ 3));
      if (triangle.determinant.abs() < 1e-12) {
        throw const FormatException('Degenerate ground triangle.');
      }
      final left = math.min(a.$1.dx, math.min(b.$1.dx, c.$1.dx));
      final right = math.max(a.$1.dx, math.max(b.$1.dx, c.$1.dx));
      final top = math.min(a.$1.dy, math.min(b.$1.dy, c.$1.dy));
      final bottom = math.max(a.$1.dy, math.max(b.$1.dy, c.$1.dy));
      for (var x = (left / 16).floor(); x <= (right / 16).floor(); x++) {
        for (var y = (top / 16).floor(); y <= (bottom / 16).floor(); y++) {
          (_cells[(x, y)] ??= []).add(triangle);
        }
      }
    }
  }

  final _cells = <(int, int), List<_GroundTriangle>>{};

  /// Every reference vertex with its height, in load order.
  late final List<(Offset, double)> vertices;

  double? heightAt(Offset point) {
    return _heightAt(point, requireStanding: false);
  }

  /// Only the first covering ground triangle can establish a physical floor.
  double? standingHeightAt(Offset point) =>
      _heightAt(point, requireStanding: true);

  double? _heightAt(Offset point, {required bool requireStanding}) {
    for (final triangle
        in _cells[((point.dx / 16).floor(), (point.dy / 16).floor())] ??
            const <_GroundTriangle>[]) {
      final value = triangle.heightAt(point);
      if (value != null)
        return !requireStanding || triangle.standingAllowed ? value : null;
    }
    return null;
  }
}

class _GroundTriangle {
  _GroundTriangle(this.a, this.b, this.c, this.standingAllowed)
      : determinant = _cross(b.$1 - a.$1, c.$1 - a.$1);
  final (Offset, double) a, b, c;
  final double determinant;
  final bool standingAllowed;
  double? heightAt(Offset point) {
    final delta = point - a.$1;
    final u = _cross(delta, c.$1 - a.$1) / determinant;
    final v = _cross(b.$1 - a.$1, delta) / determinant;
    if (u < -1e-9 || v < -1e-9 || u + v > 1 + 1e-9) return null;
    return a.$2 + u * (b.$2 - a.$2) + v * (c.$2 - a.$2);
  }
}

double _cross(Offset a, Offset b) => a.dx * b.dy - a.dy * b.dx;
