import 'dart:math' as math;
import 'dart:ui';

import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

/// A distance-normalized route used by page transitions.
///
/// Sampling by distance, instead of by waypoint index, keeps an agent's speed
/// constant even when A* produces differently sized route segments.
class AgentTransitionPath {
  AgentTransitionPath(List<Offset> points)
      : points = List<Offset>.unmodifiable(points),
        _cumulativeDistances = _buildCumulativeDistances(points);

  final List<Offset> points;
  final List<double> _cumulativeDistances;

  double get length =>
      _cumulativeDistances.isEmpty ? 0 : _cumulativeDistances.last;

  Offset positionAt(double progress) {
    if (points.isEmpty) return Offset.zero;
    if (points.length == 1 || length <= _epsilon) return points.last;

    final distance = length * progress.clamp(0.0, 1.0);
    for (var index = 1; index < points.length; index += 1) {
      if (_cumulativeDistances[index] + _epsilon < distance) continue;
      final segmentStart = _cumulativeDistances[index - 1];
      final segmentLength = _cumulativeDistances[index] - segmentStart;
      if (segmentLength <= _epsilon) return points[index];
      final localProgress = (distance - segmentStart) / segmentLength;
      return Offset.lerp(points[index - 1], points[index], localProgress) ??
          points[index];
    }
    return points.last;
  }

  static List<double> _buildCumulativeDistances(List<Offset> points) {
    if (points.isEmpty) return const [];
    final result = <double>[0];
    for (var index = 1; index < points.length; index += 1) {
      result.add(result.last + (points[index] - points[index - 1]).distance);
    }
    return List<double>.unmodifiable(result);
  }
}

class AgentTransitionPathPlanner {
  const AgentTransitionPathPlanner._();

  static Map<String, AgentTransitionPath> plan({
    required List<PageTransitionEntry> entries,
    required VisionGeometryMap? geometry,
    required bool isAttack,
    required double startAgentSize,
    required double endAgentSize,
    required CoordinateSystem coordinateSystem,
  }) {
    if (geometry == null) return const {};

    final averageAgentRadius = coordinateSystem.virtualLengthToWorld(
      (startAgentSize + endAgentSize) / 4,
    );
    final pathfinder = AgentTransitionPathfinder(
      clearance: averageAgentRadius * 0.4,
    );
    Offset centerFor(Offset position, double size) =>
        position +
        coordinateSystem.virtualOffsetToWorld(Offset(size / 2, size / 2));

    double? elevationFor(PlacedWidget widget, Offset center) {
      final override =
          widget is PlacedViewConeAgent ? widget.visionElevation : null;
      return override ??
          geometry.inferredHeightAt(isAttack: isAttack, position: center);
    }

    return {
      for (final entry in entries)
        if (entry.kind == TransitionKind.move &&
            entry.visualWidget is PlacedAgentNode)
          entry.id: () {
            final startCenter = centerFor(entry.startPos, startAgentSize);
            final endCenter = centerFor(entry.endPos, endAgentSize);
            final startElevation = elevationFor(entry.from!, startCenter);
            final endElevation = elevationFor(entry.to!, endCenter);
            final routeElevation = startElevation == null
                ? endElevation
                : endElevation == null
                    ? startElevation
                    : math.max(startElevation, endElevation);
            return pathfinder.findPath(
              start: startCenter,
              end: endCenter,
              layer: geometry.layerFor(
                isAttack: isAttack,
                elevation: routeElevation,
              ),
            );
          }(),
    };
  }
}

/// Finds a short walkable route over the collision geometry already used by
/// view cones. The search is deliberately bounded and falls back to a direct
/// route if either endpoint cannot be connected to the navigation grid.
class AgentTransitionPathfinder {
  const AgentTransitionPathfinder({
    this.gridSpacing = 18,
    this.clearance = 4,
    this.maxExpandedNodes = 12000,
  });

  final double gridSpacing;
  final double clearance;
  final int maxExpandedNodes;

  AgentTransitionPath findPath({
    required Offset start,
    required Offset end,
    required VisionGeometryLayer layer,
  }) {
    if ((end - start).distanceSquared <= _epsilon) {
      return AgentTransitionPath([start, end]);
    }
    if (_edgeIsWalkable(start, end, layer)) {
      return AgentTransitionPath([start, end]);
    }

    final bounds = layer.boundary?.outerGroup.bounds;
    if (bounds == null || !layer.contains(start) || !layer.contains(end)) {
      return AgentTransitionPath([start, end]);
    }

    final origin = bounds.topLeft;
    final startNode = _nearestConnectableNode(start, origin, layer);
    final endNode = _nearestConnectableNode(end, origin, layer);
    if (startNode == null || endNode == null) {
      return AgentTransitionPath([start, end]);
    }

    final open = <_GridNode>{startNode};
    final queue = <_OpenEntry>[];
    final cameFrom = <_GridNode, _GridNode>{};
    final gScore = <_GridNode, double>{startNode: 0};
    final fScore = <_GridNode, double>{
      startNode: _heuristic(startNode, endNode),
    };
    _push(queue, _OpenEntry(startNode, fScore[startNode]!));
    var expanded = 0;

    while (queue.isNotEmpty && expanded < maxExpandedNodes) {
      final nextEntry = _pop(queue);
      final current = nextEntry.node;
      if (!open.contains(current) ||
          nextEntry.score > (fScore[current] ?? double.infinity) + _epsilon) {
        continue;
      }
      if (current == endNode) {
        final gridPoints = _reconstruct(
          cameFrom,
          current,
        ).map((node) => _pointFor(node, origin)).toList();
        return AgentTransitionPath(_smooth([start, ...gridPoints, end], layer));
      }

      open.remove(current);
      expanded += 1;
      final currentPoint = _pointFor(current, origin);
      for (final delta in _neighborDeltas) {
        final neighbor = _GridNode(current.x + delta.x, current.y + delta.y);
        final neighborPoint = _pointFor(neighbor, origin);
        if (!bounds.inflate(gridSpacing).contains(neighborPoint) ||
            !_pointIsWalkable(neighborPoint, layer) ||
            !_edgeIsWalkable(currentPoint, neighborPoint, layer)) {
          continue;
        }
        final diagonal = delta.x != 0 && delta.y != 0;
        final tentative = (gScore[current] ?? double.infinity) +
            (diagonal ? gridSpacing * math.sqrt2 : gridSpacing);
        if (tentative >= (gScore[neighbor] ?? double.infinity)) continue;
        cameFrom[neighbor] = current;
        gScore[neighbor] = tentative;
        fScore[neighbor] = tentative + _heuristic(neighbor, endNode);
        open.add(neighbor);
        _push(queue, _OpenEntry(neighbor, fScore[neighbor]!));
      }
    }

    return AgentTransitionPath([start, end]);
  }

  _GridNode? _nearestConnectableNode(
    Offset point,
    Offset origin,
    VisionGeometryLayer layer,
  ) {
    final center = _GridNode(
      ((point.dx - origin.dx) / gridSpacing).round(),
      ((point.dy - origin.dy) / gridSpacing).round(),
    );
    _GridNode? best;
    var bestDistance = double.infinity;
    for (var radius = 0; radius <= 3; radius += 1) {
      for (var x = center.x - radius; x <= center.x + radius; x += 1) {
        for (var y = center.y - radius; y <= center.y + radius; y += 1) {
          final candidate = _GridNode(x, y);
          final candidatePoint = _pointFor(candidate, origin);
          final distance = (candidatePoint - point).distanceSquared;
          if (distance >= bestDistance ||
              !_pointIsWalkable(candidatePoint, layer) ||
              !_edgeIsWalkable(point, candidatePoint, layer)) {
            continue;
          }
          best = candidate;
          bestDistance = distance;
        }
      }
      if (best != null) return best;
    }
    return null;
  }

  bool _pointIsWalkable(Offset point, VisionGeometryLayer layer) {
    if (!layer.contains(point)) return false;
    if (clearance <= 0) return true;
    final nearby = layer.segmentIndex?.queryPoint(point, clearance) ??
        [for (var index = 0; index < layer.segments.length; index += 1) index];
    final clearanceSquared = clearance * clearance;
    return nearby.every(
      (index) =>
          visionDistanceSquaredToSegment(point, layer.segments[index]) >=
          clearanceSquared,
    );
  }

  bool _edgeIsWalkable(Offset start, Offset end, VisionGeometryLayer layer) {
    if (!layer.contains(start) || !layer.contains(end)) return false;
    final bounds = Rect.fromPoints(start, end).inflate(clearance);
    final indexes = layer.segmentIndex?.queryBounds(bounds) ??
        [for (var index = 0; index < layer.segments.length; index += 1) index];
    final route = VisionSegment(start, end);
    for (final index in indexes) {
      final wall = layer.segments[index];
      if (_segmentsIntersect(start, end, wall.start, wall.end)) return false;
      if (clearance > 0 &&
          _segmentDistanceSquared(route, wall) < clearance * clearance) {
        return false;
      }
    }
    return true;
  }

  double _segmentDistanceSquared(VisionSegment first, VisionSegment second) {
    if (_segmentsIntersect(
      first.start,
      first.end,
      second.start,
      second.end,
    )) {
      return 0;
    }
    return [
      visionDistanceSquaredToSegment(first.start, second),
      visionDistanceSquaredToSegment(first.end, second),
      visionDistanceSquaredToSegment(second.start, first),
      visionDistanceSquaredToSegment(second.end, first),
    ].reduce(math.min);
  }

  List<Offset> _smooth(List<Offset> points, VisionGeometryLayer layer) {
    if (points.length <= 2) return points;
    final result = <Offset>[points.first];
    var anchor = 0;
    while (anchor < points.length - 1) {
      var next = points.length - 1;
      while (next > anchor + 1 &&
          !_edgeIsWalkable(points[anchor], points[next], layer)) {
        next -= 1;
      }
      result.add(points[next]);
      anchor = next;
    }
    return result;
  }

  List<_GridNode> _reconstruct(
    Map<_GridNode, _GridNode> cameFrom,
    _GridNode current,
  ) {
    final route = <_GridNode>[current];
    while (cameFrom.containsKey(current)) {
      current = cameFrom[current]!;
      route.add(current);
    }
    return route.reversed.toList();
  }

  Offset _pointFor(_GridNode node, Offset origin) => Offset(
        origin.dx + node.x * gridSpacing,
        origin.dy + node.y * gridSpacing,
      );

  double _heuristic(_GridNode from, _GridNode to) {
    final dx = (from.x - to.x).abs();
    final dy = (from.y - to.y).abs();
    final diagonal = math.min(dx, dy);
    final straight = math.max(dx, dy) - diagonal;
    return gridSpacing * (diagonal * math.sqrt2 + straight);
  }

  void _push(List<_OpenEntry> heap, _OpenEntry entry) {
    heap.add(entry);
    var index = heap.length - 1;
    while (index > 0) {
      final parent = (index - 1) ~/ 2;
      if (heap[parent].score <= entry.score) break;
      heap[index] = heap[parent];
      index = parent;
    }
    heap[index] = entry;
  }

  _OpenEntry _pop(List<_OpenEntry> heap) {
    final result = heap.first;
    final tail = heap.removeLast();
    if (heap.isEmpty) return result;

    var index = 0;
    while (true) {
      final left = index * 2 + 1;
      if (left >= heap.length) break;
      final right = left + 1;
      var child = left;
      if (right < heap.length && heap[right].score < heap[left].score) {
        child = right;
      }
      if (heap[child].score >= tail.score) break;
      heap[index] = heap[child];
      index = child;
    }
    heap[index] = tail;
    return result;
  }

  bool _segmentsIntersect(Offset a, Offset b, Offset c, Offset d) {
    final ab = b - a;
    final cd = d - c;
    final denominator = visionCross(ab, cd);
    final ac = c - a;
    if (denominator.abs() <= _epsilon) {
      return visionPointIsOnSegment(a, VisionSegment(c, d), tolerance: 0.01) ||
          visionPointIsOnSegment(b, VisionSegment(c, d), tolerance: 0.01) ||
          visionPointIsOnSegment(c, VisionSegment(a, b), tolerance: 0.01) ||
          visionPointIsOnSegment(d, VisionSegment(a, b), tolerance: 0.01);
    }
    final t = visionCross(ac, cd) / denominator;
    final u = visionCross(ac, ab) / denominator;
    return t >= -_epsilon &&
        t <= 1 + _epsilon &&
        u >= -_epsilon &&
        u <= 1 + _epsilon;
  }
}

const double _epsilon = 1e-6;

const List<_GridNode> _neighborDeltas = [
  _GridNode(-1, -1),
  _GridNode(0, -1),
  _GridNode(1, -1),
  _GridNode(-1, 0),
  _GridNode(1, 0),
  _GridNode(-1, 1),
  _GridNode(0, 1),
  _GridNode(1, 1),
];

class _GridNode {
  const _GridNode(this.x, this.y);

  final int x;
  final int y;

  @override
  bool operator ==(Object other) =>
      other is _GridNode && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

class _OpenEntry {
  const _OpenEntry(this.node, this.score);

  final _GridNode node;
  final double score;
}
