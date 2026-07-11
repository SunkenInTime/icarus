import 'dart:math' as math;
import 'dart:ui';

import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';

class VisionGeometryMap {
  const VisionGeometryMap._({
    required this.map,
    required this.defaultElevation,
    required this.observerHeight,
    required this.heightField,
    required this.attackLayers,
    required this.defenseLayers,
  });

  final MapValue map;
  final double defaultElevation;
  final double observerHeight;
  final VisionHeightField? heightField;
  final List<VisionGeometryLayer> attackLayers;
  final List<VisionGeometryLayer> defenseLayers;

  List<double> get elevations => [
        for (final layer in attackLayers) layer.elevation,
      ];

  VisionGeometryLayer layerFor({required bool isAttack, double? elevation}) {
    final layers = isAttack ? attackLayers : defenseLayers;
    final target = elevation ?? defaultElevation;
    return layers.reduce((best, candidate) {
      final bestDistance = (best.elevation - target).abs();
      final candidateDistance = (candidate.elevation - target).abs();
      if (candidateDistance < bestDistance) return candidate;
      if (candidateDistance == bestDistance &&
          candidate.elevation < best.elevation) {
        return candidate;
      }
      return best;
    });
  }

  double? inferredHeightAt({
    required bool isAttack,
    required Offset position,
  }) {
    final field = heightField;
    if (field == null) return null;
    final attackPosition = isAttack ? position : _flipForDefense(position);
    return field.heightAt(attackPosition) + observerHeight;
  }

  VisionGeometryLayer layerForPosition({
    required bool isAttack,
    required Offset position,
    double? elevationOverride,
  }) {
    return layerFor(
      isAttack: isAttack,
      elevation: elevationOverride ??
          inferredHeightAt(isAttack: isAttack, position: position),
    );
  }

  /// Keeps Riot's elevation-specific internal blockers and adds the rendered
  /// SVG as the authoritative outer floor mask and boundary geometry.
  VisionGeometryMap withSvgBoundaries({
    required VisionBoundary attackBoundary,
    required VisionBoundary defenseBoundary,
  }) {
    List<VisionGeometryLayer> replace(
      List<VisionGeometryLayer> layers,
      VisionBoundary boundary,
    ) {
      // Summit postdates the available Riot export, so its compact source is
      // already the SVG fallback rather than a Riot slice.
      if (map == MapValue.summit) {
        return List.unmodifiable([
          for (final layer in layers)
            VisionGeometryLayer(
              elevation: layer.elevation,
              segments: boundary.segments,
              sourceSegments: const [],
              boundarySegments: boundary.segments,
              boundary: boundary,
            ),
        ]);
      }

      final matches = [
        for (final layer in layers)
          _matchSvgSegments(layer.riotSegments, boundary.segments),
      ];
      final globallyMatchedBoundary = <int>{
        for (final match in matches) ...match.boundaryIndices,
      };
      final alwaysOnKeys = {
        for (final segment in boundary.alwaysOnSegments) _segmentKey(segment),
      };
      final fallbackBoundaryIndices = <int>{
        for (var index = 0; index < boundary.segments.length; index += 1)
          if (!globallyMatchedBoundary.contains(index) ||
              alwaysOnKeys.contains(_segmentKey(boundary.segments[index])))
            index,
      };

      return List.unmodifiable([
        for (var layerIndex = 0; layerIndex < layers.length; layerIndex += 1)
          () {
            final layer = layers[layerIndex];
            final match = matches[layerIndex];
            final retainedRiot = <VisionSegment>[];
            final rejectedRiot = <VisionSegment>[];
            final matchedRiot = <VisionSegment>[];
            for (var index = 0; index < layer.riotSegments.length; index += 1) {
              final segment = layer.riotSegments[index];
              if (match.riotIndices.contains(index)) {
                matchedRiot.add(segment);
              } else if (_isPlausiblyOnMap(segment, boundary)) {
                retainedRiot.add(segment);
              } else {
                rejectedRiot.add(segment);
              }
            }
            final selectedBoundaryIndices = <int>{
              ...fallbackBoundaryIndices,
              ...match.boundaryIndices,
            };
            final selectedBoundary = List<VisionSegment>.unmodifiable([
              for (var index = 0; index < boundary.segments.length; index += 1)
                if (selectedBoundaryIndices.contains(index))
                  boundary.segments[index],
            ]);
            final matchedBoundary = List<VisionSegment>.unmodifiable([
              for (final index in match.boundaryIndices)
                boundary.segments[index],
            ]);
            return VisionGeometryLayer(
              elevation: layer.elevation,
              segments: List.unmodifiable([
                ...retainedRiot,
                ...selectedBoundary,
              ]),
              sourceSegments: List.unmodifiable(retainedRiot),
              matchedSourceSegments: List.unmodifiable(matchedRiot),
              matchedBoundarySegments: matchedBoundary,
              rejectedSegments: List.unmodifiable(rejectedRiot),
              boundarySegments: selectedBoundary,
              boundary: boundary,
            );
          }(),
      ]);
    }

    return VisionGeometryMap._(
      map: map,
      defaultElevation: defaultElevation,
      observerHeight: observerHeight,
      heightField: heightField,
      attackLayers: replace(attackLayers, attackBoundary),
      defenseLayers: replace(defenseLayers, defenseBoundary),
    );
  }

  static _SvgSegmentMatch _matchSvgSegments(
    List<VisionSegment> riotSegments,
    List<VisionSegment> svgSegments,
  ) {
    const exactMatchDistance = 14.0;
    const supportedMatchDistance = 40.0;
    final candidates = <int, _SvgMatchCandidate>{};
    final exact = <int>{};
    for (var svgIndex = 0; svgIndex < svgSegments.length; svgIndex += 1) {
      final svg = svgSegments[svgIndex];
      _SvgMatchCandidate? best;
      for (var riotIndex = 0; riotIndex < riotSegments.length; riotIndex += 1) {
        final riot = riotSegments[riotIndex];
        final distance = _compatibleSegmentDistance(svg, riot);
        if (distance == null || distance > supportedMatchDistance) continue;
        if (best == null || distance < best.distance) {
          best = _SvgMatchCandidate(riotIndex, distance);
        }
      }
      if (best == null) continue;
      candidates[svgIndex] = best;
      if (best.distance <= exactMatchDistance) exact.add(svgIndex);
    }

    final accepted = <int>{...exact};
    var changed = true;
    while (changed) {
      changed = false;
      for (final entry in candidates.entries) {
        if (accepted.contains(entry.key)) continue;
        if (_sharesEndpointWithAccepted(
          entry.key,
          svgSegments,
          accepted,
        )) {
          accepted.add(entry.key);
          changed = true;
        }
      }
    }
    final matchedRiotIndices = <int>{
      for (final index in accepted) candidates[index]!.riotIndex,
    };
    for (var riotIndex = 0; riotIndex < riotSegments.length; riotIndex += 1) {
      if (matchedRiotIndices.contains(riotIndex)) continue;
      var bestBoundaryIndex = -1;
      var bestDistance = double.infinity;
      for (var svgIndex = 0; svgIndex < svgSegments.length; svgIndex += 1) {
        final distance = _directRiotMatchDistance(
          riotSegments[riotIndex],
          svgSegments[svgIndex],
        );
        if (distance != null && distance < bestDistance) {
          bestDistance = distance;
          bestBoundaryIndex = svgIndex;
        }
      }
      if (bestBoundaryIndex >= 0 && bestDistance <= 60) {
        accepted.add(bestBoundaryIndex);
        matchedRiotIndices.add(riotIndex);
      }
    }
    return _SvgSegmentMatch(
      boundaryIndices: Set.unmodifiable(accepted),
      riotIndices: Set.unmodifiable(matchedRiotIndices),
    );
  }

  static double? _compatibleSegmentDistance(
    VisionSegment svg,
    VisionSegment riot,
  ) {
    const minimumDirectionCosine = 0.9659258262890683; // cos(15 degrees)
    final svgDelta = svg.end - svg.start;
    final riotDelta = riot.end - riot.start;
    final denominator = svgDelta.distance * riotDelta.distance;
    if (denominator <= _epsilon) return null;
    final cosine = ((svgDelta.dx * riotDelta.dx + svgDelta.dy * riotDelta.dy) /
            denominator)
        .abs();
    if (cosine < minimumDirectionCosine) return null;
    var distanceSquared = double.infinity;
    for (final fraction in const [0.2, 0.5, 0.8]) {
      final point = svg.start + svgDelta * fraction;
      distanceSquared = math.min(
        distanceSquared,
        _distanceSquaredToSegment(point, riot),
      );
    }
    return math.sqrt(distanceSquared);
  }

  static double? _directRiotMatchDistance(
    VisionSegment riot,
    VisionSegment svg,
  ) {
    const minimumDirectionCosine = 0.9396926207859084; // cos(20 degrees)
    final riotDelta = riot.end - riot.start;
    final svgDelta = svg.end - svg.start;
    final denominator = riotDelta.distance * svgDelta.distance;
    if (denominator <= _epsilon) return null;
    final cosine = ((riotDelta.dx * svgDelta.dx + riotDelta.dy * svgDelta.dy) /
            denominator)
        .abs();
    if (cosine < minimumDirectionCosine) return null;
    final midpoint = (riot.start + riot.end) / 2;
    return math.sqrt(_distanceSquaredToSegment(midpoint, svg));
  }

  static bool _sharesEndpointWithAccepted(
    int candidateIndex,
    List<VisionSegment> segments,
    Set<int> accepted,
  ) {
    final candidate = segments[candidateIndex];
    for (final acceptedIndex in accepted) {
      final segment = segments[acceptedIndex];
      if (_pointsNear(candidate.start, segment.start) ||
          _pointsNear(candidate.start, segment.end) ||
          _pointsNear(candidate.end, segment.start) ||
          _pointsNear(candidate.end, segment.end)) {
        return true;
      }
    }
    return false;
  }

  static bool _pointsNear(Offset left, Offset right) =>
      (left - right).distanceSquared <= 0.25;

  static String _segmentKey(VisionSegment segment) {
    String pointKey(Offset point) =>
        '${(point.dx * 10).round()},${(point.dy * 10).round()}';
    final start = pointKey(segment.start);
    final end = pointKey(segment.end);
    return start.compareTo(end) <= 0 ? '$start:$end' : '$end:$start';
  }

  static bool _isPlausiblyOnMap(
    VisionSegment segment,
    VisionBoundary boundary,
  ) {
    const sideProbeDistance = 12.0;
    const boundaryTolerance = 24.0;
    const boundaryToleranceSquared = boundaryTolerance * boundaryTolerance;
    final edge = segment.end - segment.start;
    final length = edge.distance;
    if (length <= _epsilon) return false;
    final normal = Offset(-edge.dy / length, edge.dx / length);

    for (final fraction in const [0.2, 0.5, 0.8]) {
      final point = segment.start + edge * fraction;
      if (boundary.contains(point) ||
          boundary.contains(point + normal * sideProbeDistance) ||
          boundary.contains(point - normal * sideProbeDistance)) {
        return true;
      }
      for (final boundarySegment in boundary.segments) {
        if (_distanceSquaredToSegment(point, boundarySegment) <=
            boundaryToleranceSquared) {
          return true;
        }
      }
    }
    return false;
  }

  static double _distanceSquaredToSegment(
    Offset point,
    VisionSegment segment,
  ) {
    final delta = segment.end - segment.start;
    final lengthSquared = delta.distanceSquared;
    if (lengthSquared <= _epsilon) {
      return (point - segment.start).distanceSquared;
    }
    final relative = point - segment.start;
    final projection =
        (relative.dx * delta.dx + relative.dy * delta.dy) / lengthSquared;
    final t = projection.clamp(0.0, 1.0);
    final nearest = segment.start + delta * t;
    return (point - nearest).distanceSquared;
  }

  factory VisionGeometryMap.fromCompactJson(
    MapValue map,
    Map<String, dynamic> json,
  ) {
    final version = json['version'];
    if (version != 1 && version != 2) {
      throw const FormatException('Unsupported vision geometry version.');
    }
    if (json['map'] != Maps.mapNames[map]) {
      throw FormatException('Vision geometry map mismatch for ${map.name}.');
    }
    final coordinateScale = json['coordinateScale'];
    final defaultElevation = json['defaultElevation'];
    final observerHeight = json['observerHeight'] ?? 100;
    final heightSampleValues = json['heightSamples'] ?? const <dynamic>[];
    final layerValues = json['layers'];
    if (coordinateScale is! num ||
        coordinateScale <= 0 ||
        defaultElevation is! num ||
        observerHeight is! num ||
        observerHeight <= 0 ||
        heightSampleValues is! List ||
        heightSampleValues.length % 3 != 0 ||
        layerValues is! List ||
        layerValues.isEmpty) {
      throw const FormatException('Invalid vision geometry header.');
    }

    final heightSamples = <VisionHeightSample>[];
    for (var index = 0; index < heightSampleValues.length; index += 3) {
      final x = heightSampleValues[index];
      final y = heightSampleValues[index + 1];
      final z = heightSampleValues[index + 2];
      if (x is! num || y is! num || z is! num) {
        throw const FormatException('Invalid navigation height sample.');
      }
      heightSamples.add(
        VisionHeightSample(
          position: _projectUv(
            map,
            Offset(
              x.toDouble() / coordinateScale.toDouble(),
              y.toDouble() / coordinateScale.toDouble(),
            ),
          ),
          elevation: z.toDouble(),
        ),
      );
    }

    final attackLayers = <VisionGeometryLayer>[];
    for (final layerValue in layerValues) {
      if (layerValue is! Map<String, dynamic>) {
        throw const FormatException('Invalid vision geometry layer.');
      }
      final elevation = layerValue['elevation'];
      final vertexValues = layerValue['vertices'];
      final edgeValues = layerValue['edges'];
      if (elevation is! num ||
          vertexValues is! List ||
          edgeValues is! List ||
          vertexValues.length.isOdd ||
          edgeValues.length.isOdd) {
        throw const FormatException('Invalid vision geometry arrays.');
      }

      final vertices = <Offset>[];
      for (var index = 0; index < vertexValues.length; index += 2) {
        final x = vertexValues[index];
        final y = vertexValues[index + 1];
        if (x is! num || y is! num) {
          throw const FormatException('Invalid vision geometry vertex.');
        }
        vertices.add(
          _projectUv(
            map,
            Offset(
              x.toDouble() / coordinateScale.toDouble(),
              y.toDouble() / coordinateScale.toDouble(),
            ),
          ),
        );
      }

      final segments = <VisionSegment>[];
      for (var index = 0; index < edgeValues.length; index += 2) {
        final startIndex = edgeValues[index];
        final endIndex = edgeValues[index + 1];
        if (startIndex is! int ||
            endIndex is! int ||
            startIndex < 0 ||
            endIndex < 0 ||
            startIndex >= vertices.length ||
            endIndex >= vertices.length) {
          throw const FormatException('Invalid vision geometry edge.');
        }
        final start = vertices[startIndex];
        final end = vertices[endIndex];
        if ((end - start).distanceSquared > _epsilon) {
          segments.add(VisionSegment(start, end));
        }
      }
      attackLayers.add(
        VisionGeometryLayer(
          elevation: elevation.toDouble(),
          segments: List.unmodifiable(segments),
        ),
      );
    }

    final defenseLayers = [
      for (final layer in attackLayers)
        VisionGeometryLayer(
          elevation: layer.elevation,
          segments: [
            for (final segment in layer.segments)
              VisionSegment(
                _flipForDefense(segment.start),
                _flipForDefense(segment.end),
              ),
          ],
        ),
    ];

    return VisionGeometryMap._(
      map: map,
      defaultElevation: defaultElevation.toDouble(),
      observerHeight: observerHeight.toDouble(),
      heightField: heightSamples.isEmpty
          ? null
          : VisionHeightField(List.unmodifiable(heightSamples)),
      attackLayers: List.unmodifiable(attackLayers),
      defenseLayers: List.unmodifiable(defenseLayers),
    );
  }

  static Offset _projectUv(MapValue map, Offset uv) {
    final viewBox = Maps.mapViewBox[map];
    final padding = Maps.visionGeometryPadding[map];
    if (viewBox == null || padding == null) {
      throw StateError('Missing vision projection metadata for ${map.name}.');
    }

    final rotated = _rotateUv(uv, Maps.visionGeometryCwQuarterTurns[map] ?? 0);
    final paddedWidth = viewBox.width + padding.horizontal;
    final paddedHeight = viewBox.height + padding.vertical;
    final svgPoint = Offset(
      rotated.dx * paddedWidth - padding.left,
      rotated.dy * paddedHeight - padding.top,
    );

    const normalizedHeight = 1000.0;
    const mapWidth = normalizedHeight * CoordinateSystem.defaultMapAspectRatio;
    const worldWidth = normalizedHeight * (16 / 9);
    const mapLeft = (worldWidth - mapWidth) / 2;
    final scale = math.min(
      mapWidth / viewBox.width,
      normalizedHeight / viewBox.height,
    );
    final renderedWidth = viewBox.width * scale;
    final renderedHeight = viewBox.height * scale;
    final svgOffset = Offset(
      (mapWidth - renderedWidth) / 2,
      (normalizedHeight - renderedHeight) / 2,
    );
    final projected = Offset(
      mapLeft + svgOffset.dx + svgPoint.dx * scale,
      svgOffset.dy + svgPoint.dy * scale,
    );
    final alignment = Maps.visionGeometryAlignment[map];
    if (alignment == null) return projected;
    const center = Offset(worldWidth / 2, normalizedHeight / 2);
    final centered = projected - center;
    return center +
        Offset(
          centered.dx * alignment.scaleX,
          centered.dy * alignment.scaleY,
        ) +
        alignment.offset;
  }

  static Offset _rotateUv(Offset point, int clockwiseQuarterTurns) {
    return switch (clockwiseQuarterTurns % 4) {
      1 => Offset(1 - point.dy, point.dx),
      2 => Offset(1 - point.dx, 1 - point.dy),
      3 => Offset(point.dy, 1 - point.dx),
      _ => point,
    };
  }

  static Offset _flipForDefense(Offset point) {
    const normalizedHeight = 1000.0;
    const worldWidth = normalizedHeight * (16 / 9);
    return Offset(worldWidth - point.dx, normalizedHeight - point.dy);
  }
}

enum VisionFillRule { nonZero, evenOdd }

class VisionHeightSample {
  const VisionHeightSample({
    required this.position,
    required this.elevation,
  });

  final Offset position;
  final double elevation;
}

class VisionHeightField {
  const VisionHeightField(this.samples);

  static const double _sameSurfacePositionTolerance = 4;

  final List<VisionHeightSample> samples;

  double heightAt(Offset position) {
    if (samples.isEmpty) {
      throw StateError('Cannot query an empty navigation height field.');
    }

    var nearest = samples.first;
    var nearestDistance = (nearest.position - position).distanceSquared;
    for (final sample in samples.skip(1)) {
      final distance = (sample.position - position).distanceSquared;
      if (distance < nearestDistance) {
        nearest = sample;
        nearestDistance = distance;
      }
    }

    // Reciprocal nav links and vertically stacked surfaces can produce
    // multiple samples at effectively the same map position. Prefer the
    // highest one because a top-down planner cannot disambiguate floors.
    var highestElevation = nearest.elevation;
    const toleranceSquared =
        _sameSurfacePositionTolerance * _sameSurfacePositionTolerance;
    for (final sample in samples) {
      if ((sample.position - nearest.position).distanceSquared <=
              toleranceSquared &&
          sample.elevation > highestElevation) {
        highestElevation = sample.elevation;
      }
    }
    return highestElevation;
  }
}

class VisionBoundary {
  const VisionBoundary({
    required this.segments,
    required this.contours,
    required this.fillRule,
    this.alwaysOnSegments = const [],
  });

  final List<VisionSegment> segments;
  final List<List<Offset>> contours;
  final VisionFillRule fillRule;
  final List<VisionSegment> alwaysOnSegments;

  bool contains(Offset point) {
    for (final segment in segments) {
      if (_pointIsOnSegment(point, segment)) return true;
    }

    if (fillRule == VisionFillRule.evenOdd) {
      var inside = false;
      for (final segment in segments) {
        final start = segment.start;
        final end = segment.end;
        if ((start.dy > point.dy) == (end.dy > point.dy)) continue;
        final intersectionX = start.dx +
            (point.dy - start.dy) * (end.dx - start.dx) / (end.dy - start.dy);
        if (intersectionX > point.dx) inside = !inside;
      }
      return inside;
    }

    var winding = 0;
    for (final segment in segments) {
      final start = segment.start;
      final end = segment.end;
      final side = VisionPolygon._cross(end - start, point - start);
      if (start.dy <= point.dy) {
        if (end.dy > point.dy && side > _epsilon) winding += 1;
      } else if (end.dy <= point.dy && side < -_epsilon) {
        winding -= 1;
      }
    }
    return winding != 0;
  }

  static bool _pointIsOnSegment(Offset point, VisionSegment segment) {
    const tolerance = 0.001;
    if (point.dx < segment.minX - tolerance ||
        point.dx > segment.maxX + tolerance ||
        point.dy < segment.minY - tolerance ||
        point.dy > segment.maxY + tolerance) {
      return false;
    }
    final edge = segment.end - segment.start;
    final toPoint = point - segment.start;
    return VisionPolygon._cross(edge, toPoint).abs() <=
        tolerance * math.max(1, edge.distance);
  }
}

class VisionGeometryLayer {
  const VisionGeometryLayer({
    required this.elevation,
    required this.segments,
    this.sourceSegments,
    this.matchedSourceSegments = const [],
    this.matchedBoundarySegments = const [],
    this.rejectedSegments = const [],
    this.boundarySegments = const [],
    this.boundary,
  });

  final double elevation;
  final List<VisionSegment> segments;
  final List<VisionSegment>? sourceSegments;
  final List<VisionSegment> matchedSourceSegments;
  final List<VisionSegment> matchedBoundarySegments;
  final List<VisionSegment> rejectedSegments;
  final List<VisionSegment> boundarySegments;
  final VisionBoundary? boundary;

  List<VisionSegment> get riotSegments => sourceSegments ?? segments;

  bool contains(Offset point) => boundary?.contains(point) ?? true;
}

class _SvgSegmentMatch {
  const _SvgSegmentMatch({
    required this.boundaryIndices,
    required this.riotIndices,
  });

  final Set<int> boundaryIndices;
  final Set<int> riotIndices;
}

class _SvgMatchCandidate {
  const _SvgMatchCandidate(this.riotIndex, this.distance);

  final int riotIndex;
  final double distance;
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

  bool intersectsRangeBounds(Offset origin, double range) {
    return maxX >= origin.dx - range &&
        minX <= origin.dx + range &&
        maxY >= origin.dy - range &&
        minY <= origin.dy + range;
  }
}

class VisionPolygon {
  static const double _eventAngleEpsilon = 0.00001;
  static const double _maxArcStep = math.pi / 90;

  static List<Offset> compute({
    required VisionGeometryLayer layer,
    required Offset origin,
    required double facingAngle,
    required double coneAngle,
    required double range,
  }) {
    final safeRange = math.max(0.0, range);
    final safeCone = coneAngle.clamp(0.0, math.pi * 2).toDouble();
    if (safeRange <= _epsilon || safeCone <= _epsilon) {
      return <Offset>[origin];
    }
    if (!layer.contains(origin)) return <Offset>[origin];

    final halfCone = safeCone / 2;
    final candidateSegments = [
      for (final segment in layer.segments)
        if (segment.intersectsRangeBounds(origin, safeRange)) segment,
    ];
    final relativeAngles = <double>[];
    final arcSteps = math.max(1, (safeCone / _maxArcStep).ceil());
    for (var index = 0; index <= arcSteps; index += 1) {
      relativeAngles.add(-halfCone + safeCone * index / arcSteps);
    }
    relativeAngles.add(0);

    void addEventAngle(double angle) {
      final relative = _normalizeSigned(angle - facingAngle);
      if (relative < -halfCone - _eventAngleEpsilon ||
          relative > halfCone + _eventAngleEpsilon) {
        return;
      }
      final clamped = relative.clamp(-halfCone, halfCone).toDouble();
      relativeAngles.add(clamped);
      if (clamped > -halfCone) {
        relativeAngles.add(math.max(-halfCone, clamped - _eventAngleEpsilon));
      }
      if (clamped < halfCone) {
        relativeAngles.add(math.min(halfCone, clamped + _eventAngleEpsilon));
      }
    }

    final rangeSquared = safeRange * safeRange;
    for (final segment in candidateSegments) {
      for (final endpoint in [segment.start, segment.end]) {
        final delta = endpoint - origin;
        if (delta.distanceSquared <= rangeSquared + _epsilon) {
          addEventAngle(math.atan2(delta.dy, delta.dx));
        }
      }
      for (final intersection in _segmentCircleIntersections(
        segment,
        origin,
        safeRange,
      )) {
        final delta = intersection - origin;
        addEventAngle(math.atan2(delta.dy, delta.dx));
      }
    }

    relativeAngles.sort();
    final uniqueAngles = <double>[];
    for (final angle in relativeAngles) {
      if (uniqueAngles.isEmpty ||
          (angle - uniqueAngles.last).abs() > _epsilon) {
        uniqueAngles.add(angle);
      }
    }

    final points = <Offset>[origin];
    for (final relativeAngle in uniqueAngles) {
      final angle = facingAngle + relativeAngle;
      var distance = safeRange;
      for (final segment in candidateSegments) {
        final hitDistance = _raySegmentDistance(
          origin: origin,
          angle: angle,
          segment: segment,
          maxDistance: distance,
        );
        if (hitDistance != null && hitDistance < distance) {
          distance = hitDistance;
        }
      }
      points.add(origin + Offset(math.cos(angle), math.sin(angle)) * distance);
    }
    return points;
  }

  static List<Offset> _segmentCircleIntersections(
    VisionSegment segment,
    Offset center,
    double radius,
  ) {
    final start = segment.start - center;
    final delta = segment.end - segment.start;
    final a = delta.distanceSquared;
    if (a <= _epsilon) return const [];
    final b = 2 * (start.dx * delta.dx + start.dy * delta.dy);
    final c = start.distanceSquared - radius * radius;
    final discriminant = b * b - 4 * a * c;
    if (discriminant < 0) return const [];

    final root = math.sqrt(math.max(0, discriminant));
    final values = <Offset>[];
    for (final t in [(-b - root) / (2 * a), (-b + root) / (2 * a)]) {
      if (t >= 0 && t <= 1) {
        final point = segment.start + delta * t;
        if (values.isEmpty ||
            (point - values.first).distanceSquared > _epsilon) {
          values.add(point);
        }
      }
    }
    return values;
  }

  static double? _raySegmentDistance({
    required Offset origin,
    required double angle,
    required VisionSegment segment,
    required double maxDistance,
  }) {
    final direction = Offset(math.cos(angle), math.sin(angle));
    final edge = segment.end - segment.start;
    final originToStart = segment.start - origin;
    final denominator = _cross(direction, edge);
    if (denominator.abs() <= _epsilon) return null;

    final distance = _cross(originToStart, edge) / denominator;
    final segmentPosition = _cross(originToStart, direction) / denominator;
    if (distance <= _epsilon ||
        distance > maxDistance + _epsilon ||
        segmentPosition < -_epsilon ||
        segmentPosition > 1 + _epsilon) {
      return null;
    }
    return distance;
  }

  static double _cross(Offset left, Offset right) =>
      left.dx * right.dy - left.dy * right.dx;

  static double _normalizeSigned(double angle) {
    var normalized = (angle + math.pi) % (math.pi * 2);
    if (normalized < 0) normalized += math.pi * 2;
    return normalized - math.pi;
  }
}

const double _epsilon = 0.000000001;
