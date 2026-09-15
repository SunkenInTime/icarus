import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'vision_world_projection.dart';

/// A display projection only. Occlusion queries and distances use source meters.
class DisplayWarp {
  DisplayWarp.fromJson(Map<String, dynamic> json,
      {String? expectedMap,
      String? expectedSourceGeometrySha256,
      VisionWorldProjection? expectedProjection}) {
    if (json['format'] != 'icarus-display-warp-v1' ||
        json['version'] != 1 ||
        json['outsideMesh'] != 'identity-in-source-svg' ||
        json['outerHullMaximumDisplacementSvg'] != 0) {
      throw const FormatException('Unsupported display projection.');
    }
    final name = json['map'];
    if (name is! String || !RegExp(r'^[a-z]+$').hasMatch(name)) {
      throw const FormatException('Invalid display projection map.');
    }
    map = name;
    sourceGeometrySha256 = _hash(json['sourceGeometrySha256']);
    if ((expectedMap != null && map != expectedMap) ||
        (expectedSourceGeometrySha256 != null &&
            sourceGeometrySha256 != expectedSourceGeometrySha256)) {
      throw const FormatException('Display projection source mismatch.');
    }
    final p = _object(json['projection']);
    sourceProjection = VisionWorldProjection(
        origin: _point(p['origin']),
        axisU: _point(p['axisU']),
        axisV: _point(p['axisV']));
    if (expectedProjection != null &&
        ((sourceProjection.origin - expectedProjection.origin).distance >
                1e-7 ||
            (sourceProjection.axisU - expectedProjection.axisU).distance >
                1e-9 ||
            (sourceProjection.axisV - expectedProjection.axisV).distance >
                1e-9)) {
      throw const FormatException('Display projection registration mismatch.');
    }
    final art = _object(json['art']);
    String artwork(String side, String suffix) {
      final item = _object(art[side]);
      if (item['file'] != 'assets/maps/${map}_map$suffix.svg') {
        throw const FormatException('Invalid display projection artwork.');
      }
      return _hash(item['sha256']);
    }

    attackSha256 = artwork('attack', '');
    defenseSha256 = artwork('defense', '_defense');
    final provenance = _object(json['provenance']);
    for (final key in const [
      'warpSha256',
      'compositionProofSha256',
      'sideRegistrationSha256',
      'registrationSha256',
      'controlGeometryPackSha256',
      'unwarpedControlSourcePackSha256'
    ]) {
      _hash(provenance[key]);
    }
    attackViewBox = _box(json['attackViewBox']);
    defenseViewBox = _box(json['defenseViewBox']);
    final defense = _object(json['attackToDefenseSvg']);
    if (_point(defense['axisU']) != const ui.Offset(-1, 0) ||
        _point(defense['axisV']) != const ui.Offset(0, -1)) {
      throw const FormatException('Invalid display defense reflection.');
    }
    defenseOrigin = _point(defense['origin']);
    maximumStretch = _number(json['maximumStretch']);
    if (maximumStretch < 1 || maximumStretch > 16) {
      throw const FormatException('Invalid display projection stretch.');
    }
    final sourceValues = _coordinates(json['sourceNativeMeters']);
    final targetValues = _coordinates(json['targetAttackSvg']);
    if (sourceValues.length != targetValues.length) {
      throw const FormatException('Display projection vertex count mismatch.');
    }
    for (var i = 0; i < sourceValues.length; i += 2) {
      _source.add(ui.Offset(sourceValues[i], sourceValues[i + 1]));
      _target.add(sourceProjection
          .toMeters(ui.Offset(targetValues[i], targetValues[i + 1])));
    }
    final indices = json['triangles'];
    if (indices is! List ||
        indices.isEmpty ||
        indices.length % 3 != 0 ||
        indices.length > 196608 ||
        indices.any((v) => v is! int || v < 0 || v >= _source.length)) {
      throw const FormatException('Invalid display projection triangles.');
    }
    _indices = Uint16List.fromList(indices.cast<int>());
    final edges = <(int, int), int>{};
    final uniqueTriangles = <(int, int, int)>{};
    var gridMemberships = 0;
    var measuredStretch = 1.0;
    for (var i = 0; i < _indices.length; i += 3) {
      final ids = _indices.sublist(i, i + 3);
      final sorted = ids.toList()..sort();
      if (!uniqueTriangles.add((sorted[0], sorted[1], sorted[2]))) {
        throw const FormatException('Duplicate display projection triangle.');
      }
      final source = _Triangle([for (final id in ids) _source[id]]);
      final target = _Triangle([for (final id in ids) _target[id]]);
      if (source.determinant.abs() < 1e-14 ||
          target.determinant.abs() < 1e-14 ||
          source.determinant * target.determinant <= 0) {
        throw const FormatException('Folded display projection triangle.');
      }
      final index = _sourceTriangles.length;
      _sourceTriangles.add(source);
      _targetTriangles.add(target);
      gridMemberships += _index(_sourceCells, source, index,
          _maximumGridMemberships - gridMemberships);
      gridMemberships += _index(_targetCells, target, index,
          _maximumGridMemberships - gridMemberships);
      final u = target.vector(source.weights(const ui.Offset(1, 0)));
      final v = target.vector(source.weights(const ui.Offset(0, 1)));
      final sum = u.distanceSquared + v.distanceSquared;
      final determinant = u.dx * v.dy - u.dy * v.dx;
      measuredStretch = math.max(
          measuredStretch,
          math.sqrt((sum +
                  math.sqrt(
                      math.max(0, sum * sum - 4 * determinant * determinant))) /
              2));
      for (var e = 0; e < 3; e++) {
        final a = ids[e], b = ids[(e + 1) % 3];
        final key = a < b ? (a, b) : (b, a);
        edges[key] = (edges[key] ?? 0) + 1;
      }
    }
    if (measuredStretch > maximumStretch + 1e-6) {
      throw const FormatException('Understated display projection stretch.');
    }
    for (final edge in edges.entries) {
      if (edge.value > 2 ||
          (edge.value == 1 &&
              ((_source[edge.key.$1] - _target[edge.key.$1]).distance > 1e-8 ||
                  (_source[edge.key.$2] - _target[edge.key.$2]).distance >
                      1e-8))) {
        throw const FormatException(
            'Display projection boundary must be fixed.');
      }
    }
    _validateDisjointInteriors(_sourceCells, _sourceTriangles);
    _validateDisjointInteriors(_targetCells, _targetTriangles);
  }

  late final String map, sourceGeometrySha256, attackSha256, defenseSha256;
  late final VisionWorldProjection sourceProjection;
  late final double maximumStretch;
  late final ui.Rect attackViewBox, defenseViewBox;
  late final ui.Offset defenseOrigin;
  final _source = <ui.Offset>[], _target = <ui.Offset>[];
  late final Uint16List _indices;
  final _sourceTriangles = <_Triangle>[], _targetTriangles = <_Triangle>[];
  final _sourceCells = <(int, int), List<int>>{};
  final _targetCells = <(int, int), List<int>>{};
  static const _cellSize = 8.0;
  static const _maximumGridMemberships = 2000000;

  /// Positive local determinants do not rule out two independently indexed
  /// meshes occupying the same area. Both coordinate domains must be unique.
  static void _validateDisjointInteriors(
      Map<(int, int), List<int>> cells, List<_Triangle> triangles) {
    var comparisons = 0;
    for (var index = 0; index < triangles.length; index++) {
      final triangle = triangles[index];
      final bounds = triangle.bounds;
      final candidates = <int>{};
      for (var x = (bounds.left / _cellSize).floor();
          x <= (bounds.right / _cellSize).floor();
          x++) {
        for (var y = (bounds.top / _cellSize).floor();
            y <= (bounds.bottom / _cellSize).floor();
            y++) {
          for (final other in cells[(x, y)] ?? const <int>[]) {
            if (other < index) candidates.add(other);
          }
        }
      }
      for (final other in candidates) {
        if (++comparisons > 2000000) {
          throw const FormatException(
              'Display projection overlap check limit exceeded.');
        }
        if (triangle.overlapsInterior(triangles[other])) {
          throw const FormatException('Overlapping display projection cells.');
        }
      }
    }
  }

  ui.Offset sourceAt(ui.Offset targetNative) {
    final found = _find(targetNative, _targetCells, _targetTriangles);
    return found == null
        ? targetNative
        : _sourceTriangles[found.$1].point(found.$2);
  }

  ui.Offset targetAt(ui.Offset sourceNative) {
    final found = _find(sourceNative, _sourceCells, _sourceTriangles);
    return found == null
        ? sourceNative
        : _targetTriangles[found.$1].point(found.$2);
  }

  /// Inverse local derivative; callers normalize for physical facing only.
  ui.Offset sourceDirectionAt(ui.Offset targetNative, ui.Offset direction) {
    final found = _find(targetNative, _targetCells, _targetTriangles);
    return found == null
        ? direction
        : _sourceTriangles[found.$1]
            .vector(_targetTriangles[found.$1].weights(direction));
  }

  double displacementBound(VisionWorldProjection projection) {
    var maximum = 0.0;
    for (var i = 0; i < _source.length; i++) {
      final delta = _target[i] - _source[i];
      maximum = math.max(maximum,
          (projection.axisU * delta.dx + projection.axisV * delta.dy).distance);
    }
    return maximum;
  }

  /// The caller owns and disposes the GPU object. Decoding creates none.
  ui.Vertices createMesh(VisionWorldProjection projection) {
    final positions = Float32List(_source.length * 2);
    final texture = Float32List(positions.length);
    for (var i = 0; i < _source.length; i++) {
      final s = projection.toCanvas(_source[i]);
      final t = projection.toCanvas(_target[i]);
      positions[i * 2] = t.dx;
      positions[i * 2 + 1] = t.dy;
      texture[i * 2] = s.dx;
      texture[i * 2 + 1] = s.dy;
    }
    return ui.Vertices.raw(ui.VertexMode.triangles, positions,
        textureCoordinates: texture, indices: _indices);
  }

  static (int, ui.Offset)? _find(ui.Offset point,
      Map<(int, int), List<int>> cells, List<_Triangle> triangles) {
    if (!point.dx.isFinite || !point.dy.isFinite) {
      throw const FormatException('Nonfinite display projection query.');
    }
    final key =
        ((point.dx / _cellSize).floor(), (point.dy / _cellSize).floor());
    for (final index in cells[key] ?? const <int>[]) {
      final triangle = triangles[index];
      final weights = triangle.weights(point - triangle.origin);
      if (weights.dx >= -1e-9 &&
          weights.dy >= -1e-9 &&
          weights.dx + weights.dy <= 1 + 1e-9) {
        return (index, weights);
      }
    }
    return null;
  }

  static int _index(Map<(int, int), List<int>> cells, _Triangle triangle,
      int id, int remainingMemberships) {
    final points = [
      triangle.origin,
      triangle.origin + triangle.u,
      triangle.origin + triangle.v
    ];
    final x0 = (points.map((p) => p.dx).reduce(math.min) / _cellSize).floor();
    final x1 = (points.map((p) => p.dx).reduce(math.max) / _cellSize).floor();
    final y0 = (points.map((p) => p.dy).reduce(math.min) / _cellSize).floor();
    final y1 = (points.map((p) => p.dy).reduce(math.max) / _cellSize).floor();
    final memberships = (x1 - x0 + 1) * (y1 - y0 + 1);
    if (memberships > 100000) {
      throw const FormatException('Display projection cell is too large.');
    }
    if (memberships > remainingMemberships) {
      throw const FormatException(
          'Display projection grid membership limit exceeded.');
    }
    for (var x = x0; x <= x1; x++) {
      for (var y = y0; y <= y1; y++) {
        (cells[(x, y)] ??= []).add(id);
      }
    }
    return memberships;
  }
}

class _Triangle {
  _Triangle(List<ui.Offset> points)
      : origin = points[0],
        u = points[1] - points[0],
        v = points[2] - points[0];
  final ui.Offset origin, u, v;
  late final points = [origin, origin + u, origin + v];
  late final bounds = ui.Rect.fromLTRB(
      points.map((p) => p.dx).reduce(math.min),
      points.map((p) => p.dy).reduce(math.min),
      points.map((p) => p.dx).reduce(math.max),
      points.map((p) => p.dy).reduce(math.max));

  bool overlapsInterior(_Triangle other) {
    if (!bounds.overlaps(other.bounds)) return false;
    for (final polygon in [points, other.points]) {
      for (var i = 0; i < 3; i++) {
        final edge = polygon[(i + 1) % 3] - polygon[i];
        final length = edge.distance;
        final normal = ui.Offset(-edge.dy / length, edge.dx / length);
        double project(ui.Offset p) =>
            (p.dx - origin.dx) * normal.dx + (p.dy - origin.dy) * normal.dy;
        final a = points.map(project), b = other.points.map(project);
        if (math.min(a.reduce(math.max), b.reduce(math.max)) -
                math.max(a.reduce(math.min), b.reduce(math.min)) <=
            1e-10) {
          return false;
        }
      }
    }
    return true;
  }

  double get determinant => u.dx * v.dy - u.dy * v.dx;
  ui.Offset weights(ui.Offset vector) => ui.Offset(
      (vector.dx * v.dy - vector.dy * v.dx) / determinant,
      (u.dx * vector.dy - u.dy * vector.dx) / determinant);
  ui.Offset vector(ui.Offset weights) => u * weights.dx + v * weights.dy;
  ui.Offset point(ui.Offset weights) => origin + vector(weights);
}

Map<String, dynamic> _object(dynamic value) {
  if (value is! Map<String, dynamic>)
    throw const FormatException('Invalid display projection object.');
  return value;
}

String _hash(dynamic value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw const FormatException('Invalid display projection checksum.');
  }
  return value;
}

double _number(dynamic value) {
  if (value is! num || !value.isFinite || value.abs() > 100000) {
    throw const FormatException('Invalid display projection coordinate.');
  }
  return value.toDouble();
}

ui.Offset _point(dynamic value) {
  if (value is! List || value.length != 2)
    throw const FormatException('Invalid display projection point.');
  return ui.Offset(_number(value[0]), _number(value[1]));
}

ui.Rect _box(dynamic value) {
  if (value is! List || value.length != 4)
    throw const FormatException('Invalid display projection viewBox.');
  final box = value.map(_number).toList();
  if (box[2] <= 0 || box[3] <= 0)
    throw const FormatException('Empty display projection viewBox.');
  return ui.Rect.fromLTWH(box[0], box[1], box[2], box[3]);
}

List<double> _coordinates(dynamic value) {
  if (value is! List ||
      value.length < 6 ||
      value.length > 65536 ||
      value.length % 2 != 0) {
    throw const FormatException('Invalid display projection coordinates.');
  }
  return value.map(_number).toList(growable: false);
}
