import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui';

/// Player-sized Recast floor polygons and their precomputed walking portals.
/// All coordinates are canonical attack coordinates. Display-side rotation is
/// applied only when presenting an agent path, never during a navigation query.
class NavigationGeometry {
  NavigationGeometry._({
    required this.vertices,
    required this.polygons,
    required this.triangles,
    required this.links,
    required this.components,
    required this.walkable,
    required this.agentRadiusCm,
    this.tacticalGroundChartIds = const [],
    List<NavigationVertex>? floorVertices,
    List<NavigationTriangle>? floorTriangles,
  })  : _floorVertices = floorVertices ?? vertices,
        _floorTriangles = floorTriangles ?? triangles {
    void indexTriangles(List<NavigationVertex> vertices,
        List<NavigationTriangle> triangles, Map<(int, int), List<int>> cells) {
      for (var i = 0; i < triangles.length; i++) {
        final triangle = triangles[i];
        final points = triangle.vertices.map((v) => vertices[v].position);
        final bounds = _bounds(points);
        for (var x = (bounds.left / _cellSize).floor();
            x <= (bounds.right / _cellSize).floor();
            x++) {
          for (var y = (bounds.top / _cellSize).floor();
              y <= (bounds.bottom / _cellSize).floor();
              y++) {
            (cells[(x, y)] ??= []).add(i);
          }
        }
      }
    }

    indexTriangles(_floorVertices, _floorTriangles, _triangleCells);
    if (floorTriangles != null) {
      indexTriangles(vertices, triangles, _fallbackTriangleCells);
    }
    _centers = [
      for (final polygon in polygons)
        polygon.map((i) => vertices[i].position).reduce((a, b) => a + b) /
            polygon.length.toDouble(),
    ];
    _adjacency = List.generate(polygons.length, (_) => <NavigationPortal>[]);
    for (final portal in links) {
      _adjacency[portal.from].add(portal);
    }
  }

  factory NavigationGeometry.fromJson(
    Map<String, dynamic> data, {
    required Offset Function(Offset) projectUv,
  }) {
    if (data['schemaVersion'] != 1) {
      throw const FormatException('Unsupported navigation data version');
    }
    final scale = (data['coordinateScale'] as num).toDouble();
    if (!scale.isFinite || scale <= 0) {
      throw const FormatException('Invalid navigation coordinate scale');
    }
    final flat = (data['vertices'] as List).cast<num>();
    if (flat.length % 3 != 0 || flat.any((v) => !v.isFinite)) {
      throw const FormatException('Invalid navigation vertices');
    }
    final refined = (data['refinedFloorHeightsCm'] as List?)?.cast<num?>();
    if (refined != null && refined.length != flat.length ~/ 3) {
      throw const FormatException('Refined navigation heights do not match');
    }
    final vertices = [
      for (var i = 0; i < flat.length; i += 3)
        NavigationVertex(
          projectUv(Offset(flat[i] / scale, flat[i + 1] / scale)),
          (refined?[i ~/ 3] ?? flat[i + 2]).toDouble(),
        ),
    ];
    if (vertices.any((v) =>
        !v.floorHeight.isFinite ||
        !v.position.dx.isFinite ||
        !v.position.dy.isFinite)) {
      throw const FormatException('Nonfinite navigation projection');
    }
    final polygons = [
      for (final polygon in data['polygons'] as List)
        List<int>.unmodifiable((polygon as List).cast<int>()),
    ];
    bool vertexValid(int i) => i >= 0 && i < vertices.length;
    bool polygonValid(int i) => i >= 0 && i < polygons.length;
    if (polygons.any((p) => p.length < 3 || !p.every(vertexValid))) {
      throw const FormatException('Invalid navigation polygon');
    }
    final triangleData = (data['triangles'] as List).cast<int>();
    if (triangleData.length % 4 != 0) {
      throw const FormatException('Invalid navigation triangles');
    }
    final triangles = <NavigationTriangle>[];
    for (var i = 0; i < triangleData.length; i += 4) {
      final indices = triangleData.sublist(i + 1, i + 4);
      if (!polygonValid(triangleData[i]) || !indices.every(vertexValid)) {
        throw const FormatException('Invalid navigation triangle index');
      }
      final a = vertices[indices[0]].position;
      final b = vertices[indices[1]].position;
      final c = vertices[indices[2]].position;
      if (_cross(b - a, c - a).abs() < _epsilon) {
        throw const FormatException('Degenerate navigation floor triangle');
      }
      triangles.add(NavigationTriangle(triangleData[i], indices));
    }
    final linkData = (data['links'] as List).cast<num>();
    if (linkData.length % 6 != 0 || linkData.any((v) => !v.isFinite)) {
      throw const FormatException('Invalid navigation portals');
    }
    final links = <NavigationPortal>[];
    for (var i = 0; i < linkData.length; i += 6) {
      final from = linkData[i].toInt(), to = linkData[i + 1].toInt();
      if (!polygonValid(from) ||
          !polygonValid(to) ||
          from == to ||
          from != linkData[i] ||
          to != linkData[i + 1]) {
        throw const FormatException('Invalid navigation portal index');
      }
      links.add(NavigationPortal(
        from,
        to,
        projectUv(Offset(linkData[i + 2] / scale, linkData[i + 3] / scale)),
        projectUv(Offset(linkData[i + 4] / scale, linkData[i + 5] / scale)),
      ));
    }
    final components = (data['components'] as List).cast<int>();
    final walkable = (data['walkable'] as List).cast<bool>();
    final chartIds = (data['tacticalGroundChartIds'] as List?)?.cast<int>();
    if (chartIds != null &&
        (chartIds.length != polygons.length ||
            chartIds.any((chart) => chart < 0 || chart > 1))) {
      throw const FormatException('Invalid navigation ground-chart selection');
    }
    if (components.length != polygons.length ||
        walkable.length != polygons.length ||
        links.any((p) =>
            !walkable[p.from] ||
            !walkable[p.to] ||
            components[p.from] != components[p.to])) {
      throw const FormatException('Invalid navigation connectivity');
    }
    final source = data['source'] as Map<String, dynamic>?;
    List<NavigationVertex>? floorVertices;
    List<NavigationTriangle>? floorTriangles;
    final floorMesh = data['floorMesh'] as Map<String, dynamic>?;
    if (floorMesh != null) {
      final floorScale = (floorMesh['coordinateScale'] as num).toDouble();
      final floorData = (floorMesh['vertices'] as List).cast<num>();
      final floorIndices = (floorMesh['triangles'] as List).cast<int>();
      if (!floorScale.isFinite ||
          floorScale <= 0 ||
          floorData.length % 3 != 0 ||
          floorIndices.length % 4 != 0 ||
          floorData.any((v) => !v.isFinite)) {
        throw const FormatException('Invalid detailed navigation floor');
      }
      floorVertices = [
        for (var i = 0; i < floorData.length; i += 3)
          NavigationVertex(
              projectUv(Offset(
                  floorData[i] / floorScale, floorData[i + 1] / floorScale)),
              floorData[i + 2].toDouble())
      ];
      floorTriangles = [];
      for (var i = 0; i < floorIndices.length; i += 4) {
        final indices = floorIndices.sublist(i + 1, i + 4);
        if (!polygonValid(floorIndices[i]) ||
            indices.any((v) => v < 0 || v >= floorVertices!.length)) {
          throw const FormatException('Invalid detailed floor triangle index');
        }
        final a = floorVertices[indices[0]].position;
        final b = floorVertices[indices[1]].position;
        final c = floorVertices[indices[2]].position;
        // Clipping at real stair edges creates valid narrow triangles. Use a
        // numeric zero threshold here, not the coarser route tolerance.
        if (_cross(b - a, c - a).abs() < 1e-14) {
          throw const FormatException('Degenerate detailed floor triangle');
        }
        floorTriangles.add(NavigationTriangle(floorIndices[i], indices));
      }
    }
    return NavigationGeometry._(
      vertices: List.unmodifiable(vertices),
      polygons: List.unmodifiable(polygons),
      triangles: List.unmodifiable(triangles),
      links: List.unmodifiable(links),
      components: List.unmodifiable(components),
      walkable: List.unmodifiable(walkable),
      tacticalGroundChartIds:
          chartIds == null ? const [] : List.unmodifiable(chartIds),
      agentRadiusCm: (source?['agentRadiusCm'] as num?)?.toDouble() ?? 42,
      floorVertices:
          floorVertices == null ? null : List.unmodifiable(floorVertices),
      floorTriangles:
          floorTriangles == null ? null : List.unmodifiable(floorTriangles),
    );
  }

  final List<NavigationVertex> vertices;
  final List<List<int>> polygons;
  final List<NavigationTriangle> triangles;
  final List<NavigationPortal> links;
  final List<int> components;
  final List<bool> walkable;
  final double agentRadiusCm;
  final List<int> tacticalGroundChartIds;
  int get maximumGroundChartId => tacticalGroundChartIds.contains(1) ? 1 : 0;
  final List<NavigationVertex> _floorVertices;
  final List<NavigationTriangle> _floorTriangles;
  static const double _cellSize = 32;
  final Map<(int, int), List<int>> _triangleCells = {};
  final Map<(int, int), List<int>> _fallbackTriangleCells = {};
  late final List<Offset> _centers;
  late final List<List<NavigationPortal>> _adjacency;
  final LinkedHashMap<_RouteKey, NavigationRoute> _routes = LinkedHashMap();

  /// Standing floor surfaces under the point. Overlapping floors stay distinct.
  /// The visibility bake uses the same walkable-parent domain.
  List<double> floorHeightsAt(Offset position) {
    final heights = <double>[];
    for (final location in _locationsAt(position)) {
      if (!heights.any((h) => (h - location.height).abs() < .5)) {
        heights.add(location.height);
      }
    }
    return heights..sort();
  }

  double? floorHeightAt(Offset position, {double? preferredElevation}) {
    final heights = floorHeightsAt(position);
    if (heights.isEmpty) return null;
    if (preferredElevation == null) return heights.first;
    return heights.reduce((a, b) =>
        (b - preferredElevation).abs() < (a - preferredElevation).abs()
            ? b
            : a);
  }

  /// The offline sheet label follows navigation connections, including the
  /// approach to a bridge where lower/upper fields have the same local height.
  int groundChartAt(Offset position, {double? preferredElevation}) {
    if (tacticalGroundChartIds.isEmpty) return 0;
    final locations = _locationsAt(position);
    if (locations.isNotEmpty) {
      final selected = locations.reduce((a, b) => preferredElevation == null
          ? (b.height < a.height ? b : a)
          : ((b.height - preferredElevation).abs() <
                  (a.height - preferredElevation).abs()
              ? b
              : a));
      return tacticalGroundChartIds[selected.polygon];
    }
    // Painted wall edges extend past the player-radius nav inset. Continue the
    // nearest local sheet there without inventing a walkable path.
    final cx = (position.dx / _cellSize).floor();
    final cy = (position.dy / _cellSize).floor();
    final nearby = <int>{};
    for (var x = cx - 1; x <= cx + 1; x++) {
      for (var y = cy - 1; y <= cy + 1; y++) {
        for (final index in _triangleCells[(x, y)] ?? const <int>[]) {
          nearby.add(_floorTriangles[index].polygon);
        }
      }
    }
    var bestDistance = double.infinity, bestHeight = double.infinity;
    var chart = 0;
    for (final parent in nearby) {
      if (!walkable[parent]) continue;
      final polygon = polygons[parent];
      var distance = double.infinity;
      for (var i = 0; i < polygon.length; i++) {
        final a = vertices[polygon[i]].position;
        final edge = vertices[polygon[(i + 1) % polygon.length]].position - a;
        final delta = position - a;
        final t = edge.distanceSquared == 0
            ? 0.0
            : ((delta.dx * edge.dx + delta.dy * edge.dy) / edge.distanceSquared)
                .clamp(0.0, 1.0);
        distance = math.min(distance, (delta - edge * t).distanceSquared);
      }
      final height =
          polygon.map((i) => vertices[i].floorHeight).reduce((a, b) => a + b) /
              polygon.length;
      final heightDistance = preferredElevation == null
          ? height
          : (height - preferredElevation).abs();
      if (distance < bestDistance - 1e-8 ||
          ((distance - bestDistance).abs() <= 1e-8 &&
              heightDistance < bestHeight)) {
        bestDistance = distance;
        bestHeight = heightDistance;
        chart = tacticalGroundChartIds[parent];
      }
    }
    return chart;
  }

  List<_Location> _locationsAt(Offset point) {
    if (!point.dx.isFinite || !point.dy.isFinite) return const [];
    final cell =
        ((point.dx / _cellSize).floor(), (point.dy / _cellSize).floor());
    final sourceLocations = <int, _Location>{};
    final result = <int, _Location>{};
    final parentContainment = <int, bool>{};
    bool containsParent(int polygon) =>
        parentContainment.putIfAbsent(polygon, () {
          final indices = polygons[polygon];
          var positive = false, negative = false;
          for (var i = 0; i < indices.length; i++) {
            final a = vertices[indices[i]].position;
            final b = vertices[indices[(i + 1) % indices.length]].position;
            final side = _cross(b - a, point - a);
            positive = positive || side > 0;
            negative = negative || side < 0;
            if (positive && negative) return false;
          }
          return true;
        });
    void collect(List<int> candidates, List<NavigationVertex> vertices,
        List<NavigationTriangle> triangles, Map<int, _Location> target,
        {bool requireSourceParent = false}) {
      for (final index in candidates) {
        final t = triangles[index];
        if (!walkable[t.polygon]) continue;
        if (requireSourceParent && !sourceLocations.containsKey(t.polygon))
          continue;
        final a = vertices[t.vertices[0]],
            b = vertices[t.vertices[1]],
            c = vertices[t.vertices[2]];
        final v0 = b.position - a.position, v1 = c.position - a.position;
        final relative = point - a.position;
        final denominator = _cross(v0, v1);
        final u = _cross(relative, v1) / denominator;
        final v = _cross(v0, relative) / denominator;
        if (u < -_epsilon || v < -_epsilon || u + v > 1 + _epsilon) continue;
        if (!requireSourceParent && !containsParent(t.polygon)) continue;
        final height = a.floorHeight +
            u * (b.floorHeight - a.floorHeight) +
            v * (c.floorHeight - a.floorHeight);
        // An underlying floor and stair tread can share a parent. The downward
        // reference sees the upper admitted surface. Different parent polygons
        // remain distinct floors, even at the same XY position.
        if (height > (target[t.polygon]?.height ?? -double.infinity)) {
          target[t.polygon] = _Location(t.polygon, height);
        }
      }
    }

    final sourceIndex = _fallbackTriangleCells.isEmpty
        ? _triangleCells
        : _fallbackTriangleCells;
    collect(
        sourceIndex[cell] ?? const [], vertices, triangles, sourceLocations);
    if (identical(_floorTriangles, triangles))
      return sourceLocations.values.toList();
    // Detailed XYZ clipping has finer quantization than the native UV polygon.
    // Restrict it to the same encoded parent used by the visibility bake.
    collect(_triangleCells[cell] ?? const [], _floorVertices, _floorTriangles,
        result,
        requireSourceParent: true);
    for (final entry in sourceLocations.entries) {
      result.putIfAbsent(entry.key, () => entry.value);
    }
    return result.values.toList();
  }

  _Location? _locate(Offset point, double? height) {
    final locations = _locationsAt(point);
    if (locations.isEmpty) return null;
    locations.sort((a, b) {
      final heightOrder = height == null
          ? a.height.compareTo(b.height)
          : (a.height - height).abs().compareTo((b.height - height).abs());
      return heightOrder != 0 ? heightOrder : a.polygon.compareTo(b.polygon);
    });
    return locations.first;
  }

  NavigationRoute findRoute(
      {required Offset start,
      required Offset end,
      double? startFloorHeight,
      double? endFloorHeight}) {
    final _RouteKey key = (start, end, startFloorHeight, endFloorHeight);
    final cached = _routes.remove(key);
    if (cached != null) {
      _routes[key] = cached;
      return cached;
    }
    final route = _findRoute(start, end, startFloorHeight, endFloorHeight);
    _routes[key] = route;
    if (_routes.length > 128) _routes.remove(_routes.keys.first);
    return route;
  }

  NavigationRoute _findRoute(
      Offset start, Offset end, double? startHeight, double? endHeight) {
    final from = _locate(start, startHeight), to = _locate(end, endHeight);
    if (from == null || to == null) {
      return const NavigationRoute.unreachable('endpoint-outside-navigation');
    }
    if (components[from.polygon] != components[to.polygon]) {
      return const NavigationRoute.unreachable('disconnected-floors');
    }
    if (from.polygon == to.polygon) return NavigationRoute([start, end], 0);
    final scores = List<double>.filled(polygons.length, double.infinity);
    final previous = List<NavigationPortal?>.filled(polygons.length, null);
    final heap = <_Open>[];
    scores[from.polygon] = 0;
    _push(
        heap, _Open(from.polygon, 0, (_centers[from.polygon] - end).distance));
    var expanded = 0;
    while (heap.isNotEmpty) {
      final entry = _pop(heap);
      if (entry.cost > scores[entry.polygon] + _epsilon) continue;
      if (entry.polygon == to.polygon) {
        final corridor = <NavigationPortal>[];
        var current = to.polygon;
        while (current != from.polygon) {
          final portal = previous[current]!;
          corridor.add(portal);
          current = portal.from;
        }
        return NavigationRoute(
            _funnel(start, end, corridor.reversed.toList()), expanded);
      }
      expanded++;
      for (final portal in _adjacency[entry.polygon]) {
        final cost =
            entry.cost + (_centers[portal.from] - _centers[portal.to]).distance;
        if (cost + _epsilon >= scores[portal.to]) continue;
        scores[portal.to] = cost;
        previous[portal.to] = portal;
        _push(
            heap,
            _Open(
                portal.to, cost, cost + (_centers[portal.to] - end).distance));
      }
    }
    return const NavigationRoute.unreachable('no-connected-route');
  }

  List<Offset> _funnel(
      Offset start, Offset end, List<NavigationPortal> corridor) {
    final left = <Offset>[start], right = <Offset>[start];
    for (final portal in corridor) {
      final direction = _centers[portal.to] - _centers[portal.from];
      final midpoint = (portal.a + portal.b) / 2;
      if (_cross(direction, portal.a - midpoint) < 0) {
        left.add(portal.a);
        right.add(portal.b);
      } else {
        left.add(portal.b);
        right.add(portal.a);
      }
    }
    left.add(end);
    right.add(end);
    final result = <Offset>[start];
    var apex = start, portalLeft = start, portalRight = start;
    var apexIndex = 0, leftIndex = 0, rightIndex = 0;
    for (var i = 1; i < left.length; i++) {
      final nextLeft = left[i], nextRight = right[i];
      if (_cross(portalRight - apex, nextRight - apex) <= 0) {
        if (_same(apex, portalRight) ||
            _cross(portalLeft - apex, nextRight - apex) > 0) {
          portalRight = nextRight;
          rightIndex = i;
        } else {
          result.add(portalLeft);
          apex = portalLeft;
          apexIndex = leftIndex;
          portalLeft = apex;
          portalRight = apex;
          leftIndex = apexIndex;
          rightIndex = apexIndex;
          i = apexIndex;
          continue;
        }
      }
      if (_cross(portalLeft - apex, nextLeft - apex) >= 0) {
        if (_same(apex, portalLeft) ||
            _cross(portalRight - apex, nextLeft - apex) < 0) {
          portalLeft = nextLeft;
          leftIndex = i;
        } else {
          result.add(portalRight);
          apex = portalRight;
          apexIndex = rightIndex;
          portalLeft = apex;
          portalRight = apex;
          leftIndex = apexIndex;
          rightIndex = apexIndex;
          i = apexIndex;
        }
      }
    }
    if (!_same(result.last, end)) result.add(end);
    return List.unmodifiable(result);
  }
}

class NavigationVertex {
  const NavigationVertex(this.position, this.floorHeight);
  final Offset position;
  final double floorHeight;
}

class NavigationTriangle {
  NavigationTriangle(this.polygon, List<int> vertices)
      : vertices = List.unmodifiable(vertices);
  final int polygon;
  final List<int> vertices;
}

class NavigationPortal {
  const NavigationPortal(this.from, this.to, this.a, this.b);
  final int from, to;
  final Offset a, b;
}

class NavigationRoute {
  NavigationRoute(List<Offset> points, this.expandedPolygons)
      : points = List.unmodifiable(points),
        failure = null;
  const NavigationRoute.unreachable(this.failure)
      : points = const [],
        expandedPolygons = 0;
  final List<Offset> points;
  final int expandedPolygons;
  final String? failure;
  bool get isReachable => failure == null;
}

class _Location {
  const _Location(this.polygon, this.height);
  final int polygon;
  final double height;
}

typedef _RouteKey = (Offset, Offset, double?, double?);

class _Open {
  const _Open(this.polygon, this.cost, this.score);
  final int polygon;
  final double cost, score;
}

void _push(List<_Open> heap, _Open value) {
  heap.add(value);
  var i = heap.length - 1;
  while (i > 0) {
    final parent = (i - 1) ~/ 2;
    if (heap[parent].score <= value.score) break;
    heap[i] = heap[parent];
    i = parent;
  }
  heap[i] = value;
}

_Open _pop(List<_Open> heap) {
  final result = heap.first, tail = heap.removeLast();
  if (heap.isEmpty) return result;
  var i = 0;
  while (i * 2 + 1 < heap.length) {
    var child = i * 2 + 1;
    if (child + 1 < heap.length && heap[child + 1].score < heap[child].score)
      child++;
    if (heap[child].score >= tail.score) break;
    heap[i] = heap[child];
    i = child;
  }
  heap[i] = tail;
  return result;
}

Rect _bounds(Iterable<Offset> points) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final p in points) {
    minX = math.min(minX, p.dx);
    minY = math.min(minY, p.dy);
    maxX = math.max(maxX, p.dx);
    maxY = math.max(maxY, p.dy);
  }
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}

double _cross(Offset a, Offset b) => a.dx * b.dy - a.dy * b.dx;
bool _same(Offset a, Offset b) => (a - b).distanceSquared < _epsilon;
const double _epsilon = 1e-7;
