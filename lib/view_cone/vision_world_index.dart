import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:icarus/view_cone/vision_collision.dart';
import 'package:icarus/view_cone/vision_world_segments.dart';

/// Exact ray queries over the line segments baked from a horizontal world slice.
/// The bounds only discard impossible hits. They never round a ray or its hit.
class VisionWorldIndex {
  VisionWorldIndex(
    this.segments, {
    this.planarized = false,
    bool spatiallyOrdered = false,
  }) {
    _packed = segments is VisionWorldSegments
        ? segments as VisionWorldSegments
        : null;
    if (_packed == null) {
      for (final segment in segments) {
        if (segment.collisionRadius != 0 ||
            segment.additionalCollisionPolygons.isNotEmpty) {
          throw ArgumentError(
            'World slices must contain unthickened segments.',
          );
        }
      }
    }
    final nodes = _countNodes(segments.length);
    _bounds = Float64List(nodes * 4);
    _nodes = Int32List(nodes * 2);
    _edgeOrder = spatiallyOrdered ? null : Int32List(segments.length);
    _root = segments.isEmpty
        ? -1
        : spatiallyOrdered
            ? _buildOrdered(0, segments.length)
            : _build(List<int>.generate(segments.length, (index) => index));
  }

  final List<VisionSegment> segments;
  late final VisionWorldSegments? _packed;

  /// Offline planarization splits every crossing into explicit endpoints.
  /// Only then can hidden endpoint events be omitted from a visibility sweep.
  final bool planarized;
  late final int _root;
  late final Float64List _bounds;
  // Internal nodes store child indexes. Leaves store -start-1 and end in the
  // edge order. Ordered offline geometry already uses the identity edge order.
  late final Int32List _nodes;
  late final Int32List? _edgeOrder;
  var _nextNode = 0;
  var _nextLeaf = 0;

  static int _countNodes(int length) {
    if (length == 0) return 0;
    if (length <= 8) return 1;
    final middle = length ~/ 2;
    return 1 + _countNodes(middle) + _countNodes(length - middle);
  }

  void _writeBounds(
    int node,
    double minX,
    double minY,
    double maxX,
    double maxY,
  ) {
    final offset = node * 4;
    _bounds[offset] = minX;
    _bounds[offset + 1] = minY;
    _bounds[offset + 2] = maxX;
    _bounds[offset + 3] = maxY;
  }

  /// The offline writer already placed the leaves of a median-split BVH in
  /// order. Reconstruct bounds bottom-up in linear time, with no runtime sort.
  int _buildOrdered(int start, int end) {
    final node = _nextNode++;
    if (end - start > 8) {
      final middle = start + (end - start) ~/ 2;
      final left = _buildOrdered(start, middle);
      final right = _buildOrdered(middle, end);
      _nodes[node * 2] = left;
      _nodes[node * 2 + 1] = right;
      _writeBounds(
        node,
        math.min(_bounds[left * 4], _bounds[right * 4]),
        math.min(_bounds[left * 4 + 1], _bounds[right * 4 + 1]),
        math.max(_bounds[left * 4 + 2], _bounds[right * 4 + 2]),
        math.max(_bounds[left * 4 + 3], _bounds[right * 4 + 3]),
      );
      return node;
    }
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    final packed = _packed;
    for (var id = start; id < end; id++) {
      if (packed != null) {
        final ax = packed.coordinate(id, 0), ay = packed.coordinate(id, 1);
        final bx = packed.coordinate(id, 2), by = packed.coordinate(id, 3);
        minX = math.min(minX, math.min(ax, bx));
        minY = math.min(minY, math.min(ay, by));
        maxX = math.max(maxX, math.max(ax, bx));
        maxY = math.max(maxY, math.max(ay, by));
      } else {
        final segment = segments[id];
        minX = math.min(minX, segment.minX);
        minY = math.min(minY, segment.minY);
        maxX = math.max(maxX, segment.maxX);
        maxY = math.max(maxY, segment.maxY);
      }
    }
    _writeBounds(node, minX, minY, maxX, maxY);
    _nodes[node * 2] = -start - 1;
    _nodes[node * 2 + 1] = end;
    return node;
  }

  int _build(List<int> ids) {
    final node = _nextNode++;
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (final id in ids) {
      final segment = segments[id];
      minX = math.min(minX, segment.minX);
      minY = math.min(minY, segment.minY);
      maxX = math.max(maxX, segment.maxX);
      maxY = math.max(maxY, segment.maxY);
    }
    _writeBounds(node, minX, minY, maxX, maxY);
    if (ids.length <= 8) {
      _nodes[node * 2] = -_nextLeaf - 1;
      _edgeOrder!.setRange(_nextLeaf, _nextLeaf + ids.length, ids);
      _nextLeaf += ids.length;
      _nodes[node * 2 + 1] = _nextLeaf;
      return node;
    }
    final splitX = maxX - minX >= maxY - minY;
    ids.sort((left, right) {
      final a = segments[left];
      final b = segments[right];
      return splitX
          ? (a.minX + a.maxX).compareTo(b.minX + b.maxX)
          : (a.minY + a.maxY).compareTo(b.minY + b.maxY);
    });
    final middle = ids.length ~/ 2;
    _nodes[node * 2] = _build(ids.sublist(0, middle));
    _nodes[node * 2 + 1] = _build(ids.sublist(middle));
    return node;
  }

  List<VisionSegment> queryBounds(Rect bounds) => _queryBounds(bounds);

  /// A blocker with both endpoints outside may still cross the cone. Test
  /// separating half-planes, not endpoint membership, when pruning its edges.
  List<VisionSegment> queryCone({
    required Offset origin,
    required double facingAngle,
    required double coneAngle,
    required double range,
  }) =>
      _queryBounds(
        Rect.fromCircle(center: origin, radius: range),
        sector: coneAngle <= math.pi
            ? _WorldSector(origin, facingAngle, coneAngle / 2)
            : null,
      );

  List<VisionSegment> _queryBounds(Rect bounds, {_WorldSector? sector}) {
    final result = <VisionSegment>[];
    _visitBounds(
      bounds,
      sector: sector,
      visit: (id, ax, ay, bx, by) {
        result.add(segments[id]);
      },
    );
    return result;
  }

  /// Endpoint events only need coordinates. Reading packed edges directly
  /// avoids constructing stroke metadata for every candidate in a moving cone.
  /// Selection and traversal order are identical to [queryCone].
  void visitConeSegments({
    required Offset origin,
    required double facingAngle,
    required double coneAngle,
    required double range,
    required void Function(double ax, double ay, double bx, double by) visit,
  }) {
    _visitBounds(
      Rect.fromCircle(center: origin, radius: range),
      sector: coneAngle <= math.pi
          ? _WorldSector(origin, facingAngle, coneAngle / 2)
          : null,
      visit: (id, ax, ay, bx, by) => visit(ax, ay, bx, by),
    );
  }

  void _visitBounds(
    Rect bounds, {
    _WorldSector? sector,
    required void Function(int id, double ax, double ay, double bx, double by)
        visit,
  }) {
    final packed = _packed;
    void visitNode(int node) {
      final offset = node * 4;
      final minX = _bounds[offset], minY = _bounds[offset + 1];
      final maxX = _bounds[offset + 2], maxY = _bounds[offset + 3];
      if (maxX < bounds.left ||
          minX > bounds.right ||
          maxY < bounds.top ||
          minY > bounds.bottom ||
          (sector != null &&
              !sector.intersectsBounds(minX, minY, maxX, maxY))) {
        return;
      }
      final left = _nodes[node * 2], right = _nodes[node * 2 + 1];
      if (left < 0) {
        for (var edgeOffset = -left - 1; edgeOffset < right; edgeOffset++) {
          final id = _edgeOrder?[edgeOffset] ?? edgeOffset;
          if (packed != null) {
            final ax = packed.coordinate(id, 0), ay = packed.coordinate(id, 1);
            final bx = packed.coordinate(id, 2), by = packed.coordinate(id, 3);
            if (math.max(ax, bx) >= bounds.left &&
                math.min(ax, bx) <= bounds.right &&
                math.max(ay, by) >= bounds.top &&
                math.min(ay, by) <= bounds.bottom &&
                (sector == null || sector.intersectsEdge(ax, ay, bx, by))) {
              visit(id, ax, ay, bx, by);
            }
            continue;
          }
          final segment = segments[id];
          if (segment.maxX >= bounds.left &&
              segment.minX <= bounds.right &&
              segment.maxY >= bounds.top &&
              segment.minY <= bounds.bottom &&
              (sector == null ||
                  sector.intersectsEdge(
                    segment.start.dx,
                    segment.start.dy,
                    segment.end.dx,
                    segment.end.dy,
                  ))) {
            visit(
              id,
              segment.start.dx,
              segment.start.dy,
              segment.end.dx,
              segment.end.dy,
            );
          }
        }
      } else {
        visitNode(left);
        visitNode(right);
      }
    }

    final root = _root;
    if (root >= 0) visitNode(root);
  }

  double? nearestHit({
    required Offset origin,
    required Offset direction,
    required double range,
    void Function(int edge)? onNearestEdge,
  }) {
    var nearest = range;
    var found = false;
    var nearestEdge = -1;
    final packed = _packed;
    final inverseX = direction.dx.abs() < 1e-15 ? null : 1 / direction.dx;
    final inverseY = direction.dy.abs() < 1e-15 ? null : 1 / direction.dy;
    void visit(int node, double entry) {
      if (entry > nearest + 1e-9) return;
      final left = _nodes[node * 2], right = _nodes[node * 2 + 1];
      if (left < 0) {
        for (var edgeOffset = -left - 1; edgeOffset < right; edgeOffset++) {
          final id = _edgeOrder?[edgeOffset] ?? edgeOffset;
          double startX, startY, edgeX, edgeY;
          if (packed != null) {
            startX = packed.coordinate(id, 0);
            startY = packed.coordinate(id, 1);
            edgeX = packed.coordinate(id, 2) - startX;
            edgeY = packed.coordinate(id, 3) - startY;
          } else {
            final segment = segments[id];
            startX = segment.start.dx;
            startY = segment.start.dy;
            edgeX = segment.delta.dx;
            edgeY = segment.delta.dy;
          }
          final toStartX = startX - origin.dx, toStartY = startY - origin.dy;
          final denominator = direction.dx * edgeY - direction.dy * edgeX;
          final startCrossDirection =
              toStartX * direction.dy - toStartY * direction.dx;
          if (denominator.abs() <= 1e-9) {
            if (startCrossDirection.abs() > 1e-9) continue;
            final lengthSquared = direction.distanceSquared;
            if (lengthSquared == 0) continue;
            final a = (toStartX * direction.dx + toStartY * direction.dy) /
                lengthSquared;
            final b = a +
                (edgeX * direction.dx + edgeY * direction.dy) / lengthSquared;
            if (math.max(a, b) < 0) continue;
            final entry = math.max(0.0, math.min(a, b));
            if (entry <= nearest) {
              nearest = entry;
              found = true;
              nearestEdge = id;
            }
            continue;
          }
          final distance = (toStartX * edgeY - toStartY * edgeX) / denominator;
          final position = startCrossDirection / denominator;
          // A loose fractional endpoint tolerance extends long walls enough
          // to swallow both angular probes at a nearby silhouette corner.
          if (distance > 1e-9 &&
              distance <= nearest + 1e-9 &&
              position >= -1e-12 &&
              position <= 1 + 1e-12) {
            if (distance <= nearest) {
              nearest = distance;
              found = true;
              nearestEdge = id;
            }
          }
        }
        return;
      }
      final a = _entry(left, origin, inverseX, inverseY, nearest);
      final b = _entry(right, origin, inverseX, inverseY, nearest);
      if (a == null) {
        if (b != null) visit(right, b);
      } else if (b == null) {
        visit(left, a);
      } else if (a <= b) {
        visit(left, a);
        visit(right, b);
      } else {
        visit(right, b);
        visit(left, a);
      }
    }

    final root = _root;
    if (root >= 0) {
      final entry = _entry(root, origin, inverseX, inverseY, nearest);
      if (entry != null) visit(root, entry);
    }
    if (found) onNearestEdge?.call(nearestEdge);
    return found ? nearest : null;
  }

  double? _entry(
    int node,
    Offset origin,
    double? inverseX,
    double? inverseY,
    double range,
  ) {
    var near = 0.0;
    var far = range;
    final offset = node * 4;
    // This hot path visits many bounds per ray. Compute reciprocals once and
    // avoid a closure with mutable captured interval values at every node.
    if (inverseX == null) {
      if (origin.dx < _bounds[offset] - 1e-9 ||
          origin.dx > _bounds[offset + 2] + 1e-9) return null;
    } else {
      final a = (_bounds[offset] - origin.dx) * inverseX;
      final b = (_bounds[offset + 2] - origin.dx) * inverseX;
      near = math.max(near, inverseX >= 0 ? a : b);
      far = math.min(far, inverseX >= 0 ? b : a);
      if (near > far + 1e-9) return null;
    }
    if (inverseY == null) {
      if (origin.dy < _bounds[offset + 1] - 1e-9 ||
          origin.dy > _bounds[offset + 3] + 1e-9) return null;
    } else {
      final a = (_bounds[offset + 1] - origin.dy) * inverseY;
      final b = (_bounds[offset + 3] - origin.dy) * inverseY;
      near = math.max(near, inverseY >= 0 ? a : b);
      far = math.min(far, inverseY >= 0 ? b : a);
      if (near > far + 1e-9) return null;
    }
    return near;
  }
}

class _WorldSector {
  _WorldSector(this.origin, double facing, double halfCone)
      : leftX = -math.sin(facing - halfCone),
        leftY = math.cos(facing - halfCone),
        rightX = math.sin(facing + halfCone),
        rightY = -math.cos(facing + halfCone);

  final Offset origin;
  final double leftX, leftY, rightX, rightY;

  bool intersectsBounds(double minX, double minY, double maxX, double maxY) {
    bool admits(double x, double y) =>
        x * ((x >= 0 ? maxX : minX) - origin.dx) +
            y * ((y >= 0 ? maxY : minY) - origin.dy) >=
        -1e-9;
    return admits(leftX, leftY) && admits(rightX, rightY);
  }

  bool intersectsEdge(double ax, double ay, double bx, double by) {
    ax -= origin.dx;
    ay -= origin.dy;
    bx -= origin.dx;
    by -= origin.dy;
    bool admits(double x, double y) =>
        math.max(x * ax + y * ay, x * bx + y * by) >= -1e-9;
    return admits(leftX, leftY) && admits(rightX, rightY);
  }
}

typedef VisionWorldPolygonKey = ({
  Offset origin,
  double facing,
  double cone,
  double range,
  double clearance,
});

/// Keeps stationary cones across widget rebuilds without quantizing positions.
class VisionWorldPolygonCache {
  final _values = <VisionWorldPolygonKey, List<Offset>>{};
  var _vertices = 0;

  List<Offset>? get(VisionWorldPolygonKey key) {
    final value = _values.remove(key);
    if (value != null) _values[key] = value;
    return value;
  }

  List<Offset> put(VisionWorldPolygonKey key, List<Offset> polygon) {
    final value = List<Offset>.unmodifiable(polygon);
    if (value.length > 10000) return value;
    final previous = _values.remove(key);
    if (previous != null) _vertices -= previous.length;
    _values[key] = value;
    _vertices += value.length;
    while (_values.length > 64 || _vertices > 50000) {
      _vertices -= _values.remove(_values.keys.first)!.length;
    }
    return value;
  }
}
