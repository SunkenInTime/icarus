import 'dart:math' as math;
import 'dart:ui';

enum VisionCollisionKind {
  maskBoundary,
  structuralObstacle,
  structuralChain,
}

enum VisionCollisionConfidence {
  alwaysOn,
  matched,
  ambiguous,
  unmatchedDefault,
  overridden,
}

class VisionSegment {
  VisionSegment(this.start, this.end)
      : minX = math.min(start.dx, end.dx),
        maxX = math.max(start.dx, end.dx),
        minY = math.min(start.dy, end.dy),
        maxY = math.max(start.dy, end.dy);

  final Offset start;
  final Offset end;
  final double minX;
  final double maxX;
  final double minY;
  final double maxY;

  double get length => (end - start).distance;

  bool intersectsRangeBounds(Offset origin, double range) {
    return maxX >= origin.dx - range &&
        minX <= origin.dx + range &&
        maxY >= origin.dy - range &&
        minY <= origin.dy + range;
  }
}

class VisionCollisionGroup {
  VisionCollisionGroup._({
    required this.id,
    required this.points,
    required this.segments,
    required this.bounds,
    required this.kind,
    required this.isClosed,
    required this.isOuterBoundary,
    required this.nestingDepth,
    required this.requiresEvidence,
    required this.layerMask,
    required this.evidenceLayerMask,
    required this.navigationLayerMask,
    required this.observerExclusionLayerMask,
    required this.coverageByLayer,
    required this.confidence,
    required this.overrideApplied,
  });

  factory VisionCollisionGroup.geometry({
    required List<Offset> points,
    required VisionCollisionKind kind,
    required bool isClosed,
    bool isOuterBoundary = false,
    int nestingDepth = 0,
    bool requiresEvidence = false,
  }) {
    final normalized = <Offset>[...points];
    if (isClosed &&
        normalized.length >= 2 &&
        (normalized.first - normalized.last).distanceSquared > 1e-9) {
      normalized.add(normalized.first);
    }
    final normalizedPoints = List<Offset>.unmodifiable(normalized);
    final segments = List<VisionSegment>.unmodifiable([
      for (var index = 1; index < normalizedPoints.length; index += 1)
        if ((normalizedPoints[index] - normalizedPoints[index - 1])
                .distanceSquared >
            1e-9)
          VisionSegment(
            normalizedPoints[index - 1],
            normalizedPoints[index],
          ),
    ]);
    if (segments.isEmpty) {
      throw const FormatException('Collision group has no usable segments.');
    }
    final bounds = segments.skip(1).fold<Rect>(
          Rect.fromPoints(segments.first.start, segments.first.end),
          (rect, segment) => rect.expandToInclude(
            Rect.fromPoints(segment.start, segment.end),
          ),
        );
    return VisionCollisionGroup._(
      id: _stableId(kind, isClosed, normalizedPoints),
      points: normalizedPoints,
      segments: segments,
      bounds: bounds,
      kind: kind,
      isClosed: isClosed,
      isOuterBoundary: isOuterBoundary,
      nestingDepth: nestingDepth,
      requiresEvidence: requiresEvidence,
      layerMask: 0,
      evidenceLayerMask: 0,
      navigationLayerMask: 0,
      observerExclusionLayerMask: 0,
      coverageByLayer: const [],
      confidence: isOuterBoundary
          ? VisionCollisionConfidence.alwaysOn
          : VisionCollisionConfidence.unmatchedDefault,
      overrideApplied: false,
    );
  }

  final String id;
  final List<Offset> points;
  final List<VisionSegment> segments;
  final Rect bounds;
  final VisionCollisionKind kind;
  final bool isClosed;
  final bool isOuterBoundary;
  final int nestingDepth;
  final bool requiresEvidence;
  final int layerMask;
  final int evidenceLayerMask;
  final int navigationLayerMask;
  final int observerExclusionLayerMask;
  final List<double> coverageByLayer;
  final VisionCollisionConfidence confidence;
  final bool overrideApplied;

  double get perimeter =>
      segments.fold<double>(0, (sum, segment) => sum + segment.length);

  double get signedArea {
    if (!isClosed) return 0;
    var result = 0.0;
    for (var index = 1; index < points.length; index += 1) {
      final previous = points[index - 1];
      final current = points[index];
      result += previous.dx * current.dy - current.dx * previous.dy;
    }
    return result / 2;
  }

  bool activeInLayer(int index) => layerMask & (1 << index) != 0;

  bool hasEvidenceInLayer(int index) => evidenceLayerMask & (1 << index) != 0;

  bool excludesObserverInLayer(int index) =>
      observerExclusionLayerMask & (1 << index) != 0;

  bool contains(Offset point) {
    if (!isClosed || !bounds.inflate(0.001).contains(point)) return false;
    var inside = false;
    for (final segment in segments) {
      if (visionPointIsOnSegment(point, segment)) return true;
      final start = segment.start;
      final end = segment.end;
      if ((start.dy > point.dy) == (end.dy > point.dy)) continue;
      final intersectionX = start.dx +
          (point.dy - start.dy) * (end.dx - start.dx) / (end.dy - start.dy);
      if (intersectionX > point.dx) inside = !inside;
    }
    return inside;
  }

  VisionCollisionGroup classify({
    required int layerMask,
    required int evidenceLayerMask,
    required int navigationLayerMask,
    required int observerExclusionLayerMask,
    required List<double> coverageByLayer,
    required VisionCollisionConfidence confidence,
    required bool overrideApplied,
  }) {
    return VisionCollisionGroup._(
      id: id,
      points: points,
      segments: segments,
      bounds: bounds,
      kind: kind,
      isClosed: isClosed,
      isOuterBoundary: isOuterBoundary,
      nestingDepth: nestingDepth,
      requiresEvidence: requiresEvidence,
      layerMask: layerMask,
      evidenceLayerMask: evidenceLayerMask,
      navigationLayerMask: navigationLayerMask,
      observerExclusionLayerMask: observerExclusionLayerMask,
      coverageByLayer: List<double>.unmodifiable(coverageByLayer),
      confidence: confidence,
      overrideApplied: overrideApplied,
    );
  }

  static String _stableId(
    VisionCollisionKind kind,
    bool isClosed,
    List<Offset> points,
  ) {
    // 32-bit FNV-1a stays identical on the Dart VM and JavaScript targets.
    var hash = 0x811c9dc5;
    const prime = 0x01000193;
    void mix(int value) {
      hash ^= value & 0xffffffff;
      hash = (hash * prime) & 0xffffffff;
    }

    mix(kind.index);
    mix(isClosed ? 1 : 0);
    for (final point in points) {
      mix((point.dx * 10).round());
      mix((point.dy * 10).round());
    }
    return '${kind.name}_${hash.toRadixString(16).padLeft(8, '0')}';
  }
}

class VisionSegmentIndex {
  VisionSegmentIndex(
    this.segments, {
    this.cellSize = 64,
  }) {
    for (var index = 0; index < segments.length; index += 1) {
      final segment = segments[index];
      final minX = (segment.minX / cellSize).floor();
      final maxX = (segment.maxX / cellSize).floor();
      final minY = (segment.minY / cellSize).floor();
      final maxY = (segment.maxY / cellSize).floor();
      for (var x = minX; x <= maxX; x += 1) {
        for (var y = minY; y <= maxY; y += 1) {
          (_cells[(x, y)] ??= <int>[]).add(index);
        }
      }
    }
  }

  final List<VisionSegment> segments;
  final double cellSize;
  final Map<(int, int), List<int>> _cells = {};

  List<int> queryBounds(Rect bounds) {
    final minX = (bounds.left / cellSize).floor();
    final maxX = (bounds.right / cellSize).floor();
    final minY = (bounds.top / cellSize).floor();
    final maxY = (bounds.bottom / cellSize).floor();
    final result = <int>{};
    for (var x = minX; x <= maxX; x += 1) {
      for (var y = minY; y <= maxY; y += 1) {
        result.addAll(_cells[(x, y)] ?? const <int>[]);
      }
    }
    final sorted = result.where((index) {
      final segment = segments[index];
      return segment.maxX >= bounds.left &&
          segment.minX <= bounds.right &&
          segment.maxY >= bounds.top &&
          segment.minY <= bounds.bottom;
    }).toList()
      ..sort();
    return sorted;
  }

  List<int> queryPoint(Offset point, double radius) => queryBounds(
        Rect.fromCircle(center: point, radius: radius),
      );
}

double visionCross(Offset left, Offset right) =>
    left.dx * right.dy - left.dy * right.dx;

double visionDistanceSquaredToSegment(Offset point, VisionSegment segment) {
  final delta = segment.end - segment.start;
  final lengthSquared = delta.distanceSquared;
  if (lengthSquared <= 1e-9) return (point - segment.start).distanceSquared;
  final relative = point - segment.start;
  final projection =
      (relative.dx * delta.dx + relative.dy * delta.dy) / lengthSquared;
  final nearest = segment.start + delta * projection.clamp(0.0, 1.0).toDouble();
  return (point - nearest).distanceSquared;
}

bool visionPointIsOnSegment(
  Offset point,
  VisionSegment segment, {
  double tolerance = 0.001,
}) {
  if (point.dx < segment.minX - tolerance ||
      point.dx > segment.maxX + tolerance ||
      point.dy < segment.minY - tolerance ||
      point.dy > segment.maxY + tolerance) {
    return false;
  }
  return visionCross(segment.end - segment.start, point - segment.start)
          .abs() <=
      tolerance * math.max(1, segment.length);
}

String visionSegmentKey(VisionSegment segment) {
  String pointKey(Offset point) =>
      '${(point.dx * 10).round()},${(point.dy * 10).round()}';
  final start = pointKey(segment.start);
  final end = pointKey(segment.end);
  return start.compareTo(end) <= 0 ? '$start:$end' : '$end:$start';
}
