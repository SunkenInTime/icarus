import 'dart:math' as math;
import 'dart:ui';

import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/vision_collision.dart';

export 'package:icarus/view_cone/vision_collision.dart';

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

  double? inferredHeightAt({required bool isAttack, required Offset position}) {
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
      elevation:
          elevationOverride ??
          inferredHeightAt(isAttack: isAttack, position: position),
    );
  }

  /// Uses Riot's layers as evidence while keeping exact SVG groups as the only
  /// runtime collision geometry. Collision membership is atomic per authored
  /// SVG subpath, so a box can never lose only one of its sides.
  VisionGeometryMap withSvgBoundaries({
    required VisionBoundary attackBoundary,
    required VisionBoundary defenseBoundary,
    VisionGeometryOverrides overrides = const VisionGeometryOverrides(),
  }) {
    List<VisionGeometryLayer> replace(
      List<VisionGeometryLayer> layers,
      VisionBoundary boundary,
      Map<String, VisionCollisionOverride> sideOverrides, {
      required bool isAttack,
    }) {
      _validateOverrides(boundary, sideOverrides, layers);
      final allLayersMask = (1 << layers.length) - 1;
      final navigationSamples = _topmostNavigationSamples(isAttack: isAttack);
      final sourceIndexes = [
        for (final layer in layers)
          VisionSegmentIndex(layer.riotSegments, cellSize: 32),
      ];
      final matchedRiotIndices = [
        for (var index = 0; index < layers.length; index += 1) <int>{},
      ];
      final classifiedGroups = <VisionCollisionGroup>[];

      for (final group in boundary.collisionGroups) {
        final scores = [
          for (var layerIndex = 0; layerIndex < layers.length; layerIndex += 1)
            _scoreCollisionGroup(
              group,
              layers[layerIndex].riotSegments,
              sourceIndexes[layerIndex],
            ),
        ];
        var evidenceMask = 0;
        var broadEvidenceMask = 0;
        for (var layerIndex = 0; layerIndex < scores.length; layerIndex += 1) {
          final score = scores[layerIndex];
          if (score.isSupported) {
            evidenceMask |= 1 << layerIndex;
            matchedRiotIndices[layerIndex].addAll(score.riotIndices);
          } else if (score.broadCoverage >= 0.35) {
            broadEvidenceMask |= 1 << layerIndex;
          }
        }
        final navigationMask = _navigationEvidenceMask(
          group,
          layers,
          navigationSamples,
        );
        // The outer footprint is a hard safety invariant. Overrides may tune
        // authored details, but can never disable or narrow map clipping.
        final override = group.isOuterBoundary ? null : sideOverrides[group.id];
        final admitted =
            group.isOuterBoundary ||
            (group.kind != VisionCollisionKind.structuralChain &&
                !group.requiresEvidence) ||
            evidenceMask != 0 ||
            override?.enabled == true;
        final collisionEnabled = admitted && override?.enabled != false;

        var layerMask = collisionEnabled ? allLayersMask : 0;
        var observerExclusionMask = group.isOuterBoundary
            ? 0
            : navigationMask & allLayersMask;
        if (map == MapValue.summit &&
            heightField == null &&
            group.isClosed &&
            !group.isOuterBoundary) {
          observerExclusionMask = allLayersMask;
        }
        if (override != null) {
          if (layerMask != 0 && override.activeElevations != null) {
            layerMask = _maskForElevations(override.activeElevations!, layers);
          }
          layerMask &= ~_maskForElevations(override.inactiveElevations, layers);
          if (override.observerPassableElevations != null) {
            observerExclusionMask = _maskForElevations(
              override.observerPassableElevations!,
              layers,
            );
          }
        }
        final confidence = group.isOuterBoundary
            ? VisionCollisionConfidence.alwaysOn
            : override != null
            ? VisionCollisionConfidence.overridden
            : evidenceMask != 0
            ? VisionCollisionConfidence.matched
            : broadEvidenceMask != 0
            ? VisionCollisionConfidence.ambiguous
            : VisionCollisionConfidence.unmatchedDefault;
        classifiedGroups.add(
          group.classify(
            layerMask: layerMask,
            evidenceLayerMask: evidenceMask,
            navigationLayerMask: navigationMask,
            observerExclusionLayerMask: observerExclusionMask,
            coverageByLayer: [for (final score in scores) score.strictCoverage],
            confidence: confidence,
            overrideApplied: override != null,
          ),
        );
      }

      final debugGroups = List<VisionCollisionGroup>.unmodifiable(
        classifiedGroups,
      );
      return List<VisionGeometryLayer>.unmodifiable([
        for (var layerIndex = 0; layerIndex < layers.length; layerIndex += 1)
          () {
            final sourceLayer = layers[layerIndex];
            final activeGroups = List<VisionCollisionGroup>.unmodifiable([
              for (final group in classifiedGroups)
                if (group.activeInLayer(layerIndex)) group,
            ]);
            final observerGroups = List<VisionCollisionGroup>.unmodifiable([
              for (final group in classifiedGroups)
                if (group.excludesObserverInLayer(layerIndex)) group,
            ]);
            final selectedBoundary = _deduplicateSegments([
              for (final group in activeGroups) ...group.segments,
            ]);
            final matchedBoundary = _deduplicateSegments([
              for (final group in activeGroups)
                if (group.hasEvidenceInLayer(layerIndex)) ...group.segments,
            ]);
            final matchedSource = List<VisionSegment>.unmodifiable([
              for (
                var index = 0;
                index < sourceLayer.riotSegments.length;
                index += 1
              )
                if (matchedRiotIndices[layerIndex].contains(index))
                  sourceLayer.riotSegments[index],
            ]);
            final unmatchedSource = List<VisionSegment>.unmodifiable([
              for (
                var index = 0;
                index < sourceLayer.riotSegments.length;
                index += 1
              )
                if (!matchedRiotIndices[layerIndex].contains(index))
                  sourceLayer.riotSegments[index],
            ]);
            return VisionGeometryLayer(
              elevation: sourceLayer.elevation,
              segments: selectedBoundary,
              sourceSegments: const [],
              matchedSourceSegments: matchedSource,
              matchedBoundarySegments: matchedBoundary,
              rejectedSegments: unmatchedSource,
              boundarySegments: selectedBoundary,
              boundary: boundary,
              collisionGroups: activeGroups,
              observerGroups: observerGroups,
              debugCollisionGroups: debugGroups,
              layerIndex: layerIndex,
              segmentIndex: VisionSegmentIndex(selectedBoundary),
            );
          }(),
      ]);
    }

    return VisionGeometryMap._(
      map: map,
      defaultElevation: defaultElevation,
      observerHeight: observerHeight,
      heightField: heightField,
      attackLayers: replace(
        attackLayers,
        attackBoundary,
        overrides.attack,
        isAttack: true,
      ),
      defenseLayers: replace(
        defenseLayers,
        defenseBoundary,
        overrides.defense,
        isAttack: false,
      ),
    );
  }

  _ContourLayerScore _scoreCollisionGroup(
    VisionCollisionGroup group,
    List<VisionSegment> riotSegments,
    VisionSegmentIndex sourceIndex,
  ) {
    const sampleSpacing = 6.0;
    const strictDistance = 14.0;
    const broadDistance = 32.0;
    const minimumDirectionCosine = 0.9396926207859084; // cos(20 degrees)
    var totalLength = 0.0;
    var strictLength = 0.0;
    var broadLength = 0.0;
    final riotIndices = <int>{};
    for (final svg in group.segments) {
      final svgDelta = svg.end - svg.start;
      final svgLength = svgDelta.distance;
      if (svgLength <= _epsilon) continue;
      final steps = math.max(1, (svgLength / sampleSpacing).ceil());
      final sampleWeight = svgLength / steps;
      totalLength += svgLength;
      for (var step = 0; step < steps; step += 1) {
        final fraction = (step + 0.5) / steps;
        final point = svg.start + svgDelta * fraction;
        var bestDistanceSquared = double.infinity;
        var bestIndex = -1;
        for (final riotIndex in sourceIndex.queryPoint(point, broadDistance)) {
          final riot = riotSegments[riotIndex];
          final riotDelta = riot.end - riot.start;
          final denominator = svgLength * riotDelta.distance;
          if (denominator <= _epsilon) continue;
          final cosine =
              ((svgDelta.dx * riotDelta.dx + svgDelta.dy * riotDelta.dy) /
                      denominator)
                  .abs();
          if (cosine < minimumDirectionCosine) continue;
          final distanceSquared = visionDistanceSquaredToSegment(point, riot);
          if (distanceSquared < bestDistanceSquared) {
            bestDistanceSquared = distanceSquared;
            bestIndex = riotIndex;
          }
        }
        if (bestDistanceSquared <= broadDistance * broadDistance) {
          broadLength += sampleWeight;
        }
        if (bestDistanceSquared <= strictDistance * strictDistance) {
          strictLength += sampleWeight;
          if (bestIndex >= 0) riotIndices.add(bestIndex);
        }
      }
    }
    if (totalLength <= _epsilon) return const _ContourLayerScore.empty();
    return _ContourLayerScore(
      strictCoverage: strictLength / totalLength,
      broadCoverage: broadLength / totalLength,
      riotIndices: Set.unmodifiable(riotIndices),
    );
  }

  int _navigationEvidenceMask(
    VisionCollisionGroup group,
    List<VisionGeometryLayer> layers,
    List<VisionHeightSample> samples,
  ) {
    if (samples.isEmpty || group.isOuterBoundary) return 0;
    const openChainToleranceSquared = 12.0 * 12.0;
    const closedInsetSquared = 2.0 * 2.0;
    final counts = List<int>.filled(layers.length, 0);
    for (final sample in samples) {
      if (!group.bounds.inflate(12).contains(sample.position)) continue;
      final isRelevant = group.isClosed
          ? group.contains(sample.position) &&
                group.segments.every(
                  (segment) =>
                      visionDistanceSquaredToSegment(
                        sample.position,
                        segment,
                      ) >=
                      closedInsetSquared,
                )
          : group.segments.any(
              (segment) =>
                  visionDistanceSquaredToSegment(sample.position, segment) <=
                  openChainToleranceSquared,
            );
      if (!isRelevant) continue;
      counts[_nearestLayerIndex(sample.elevation + observerHeight, layers)] +=
          1;
    }
    // One nav endpoint can sit a few pixels inside an obstacle because of the
    // independent Riot/SVG traces. Require corroboration for detail objects;
    // a nested base contour only needs one sample so small raised floors work.
    final minimumSamples = group.kind == VisionCollisionKind.maskBoundary
        ? 1
        : 2;
    var result = 0;
    for (var index = 0; index < counts.length; index += 1) {
      if (counts[index] >= minimumSamples) result |= 1 << index;
    }
    return result;
  }

  List<VisionHeightSample> _topmostNavigationSamples({required bool isAttack}) {
    final field = heightField;
    if (field == null || field.samples.isEmpty) return const [];
    const tolerance = VisionHeightField._sameSurfacePositionTolerance;
    const toleranceSquared = tolerance * tolerance;
    final sorted = [...field.samples]
      ..sort((left, right) {
        final elevation = right.elevation.compareTo(left.elevation);
        if (elevation != 0) return elevation;
        final x = left.position.dx.compareTo(right.position.dx);
        return x != 0 ? x : left.position.dy.compareTo(right.position.dy);
      });
    final buckets = <(int, int), List<VisionHeightSample>>{};
    final accepted = <VisionHeightSample>[];
    for (final sample in sorted) {
      final cellX = (sample.position.dx / tolerance).floor();
      final cellY = (sample.position.dy / tolerance).floor();
      var shadowedByHigherSurface = false;
      for (var x = cellX - 1; x <= cellX + 1; x += 1) {
        for (var y = cellY - 1; y <= cellY + 1; y += 1) {
          if ((buckets[(x, y)] ?? const <VisionHeightSample>[]).any(
            (candidate) =>
                (candidate.position - sample.position).distanceSquared <=
                toleranceSquared,
          )) {
            shadowedByHigherSurface = true;
            break;
          }
        }
        if (shadowedByHigherSurface) break;
      }
      if (shadowedByHigherSurface) continue;
      accepted.add(sample);
      (buckets[(cellX, cellY)] ??= <VisionHeightSample>[]).add(sample);
    }
    if (isAttack) return List.unmodifiable(accepted);
    return List.unmodifiable([
      for (final sample in accepted)
        VisionHeightSample(
          position: _flipForDefense(sample.position),
          elevation: sample.elevation,
        ),
    ]);
  }

  static int _nearestLayerIndex(
    double elevation,
    List<VisionGeometryLayer> layers,
  ) {
    var best = 0;
    var bestDistance = (layers.first.elevation - elevation).abs();
    for (var index = 1; index < layers.length; index += 1) {
      final distance = (layers[index].elevation - elevation).abs();
      if (distance < bestDistance) {
        best = index;
        bestDistance = distance;
      }
    }
    return best;
  }

  static int _maskForElevations(
    Iterable<double> elevations,
    List<VisionGeometryLayer> layers,
  ) {
    var result = 0;
    for (final elevation in elevations) {
      final index = layers.indexWhere(
        (layer) => (layer.elevation - elevation).abs() <= 0.001,
      );
      if (index < 0) {
        throw FormatException(
          'Unknown vision elevation $elevation; expected one of '
          '${layers.map((layer) => layer.elevation).join(', ')}.',
        );
      }
      result |= 1 << index;
    }
    return result;
  }

  static void _validateOverrides(
    VisionBoundary boundary,
    Map<String, VisionCollisionOverride> overrides,
    List<VisionGeometryLayer> layers,
  ) {
    final groups = {
      for (final group in boundary.collisionGroups) group.id: group,
    };
    for (final entry in overrides.entries) {
      final group = groups[entry.key];
      if (group == null) {
        throw FormatException('Unknown vision contour id ${entry.key}.');
      }
      if (group.isOuterBoundary) {
        throw const FormatException(
          'The outer vision contour cannot be overridden.',
        );
      }
      final override = entry.value;
      final active = override.activeElevations;
      final activeMask = active == null
          ? 0
          : _maskForElevations(active, layers);
      final inactiveMask = _maskForElevations(
        override.inactiveElevations,
        layers,
      );
      final passable = override.observerPassableElevations;
      if (passable != null) _maskForElevations(passable, layers);
      if (active != null && activeMask & inactiveMask != 0) {
        throw FormatException(
          'Contour ${entry.key} has conflicting active/inactive elevations.',
        );
      }
    }
  }

  static List<VisionSegment> _deduplicateSegments(
    Iterable<VisionSegment> segments,
  ) {
    final keys = <String>{};
    return List<VisionSegment>.unmodifiable([
      for (final segment in segments)
        if (keys.add(visionSegmentKey(segment))) segment,
    ]);
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
        Offset(centered.dx * alignment.scaleX, centered.dy * alignment.scaleY) +
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

/// Per-map exceptions for the rare SVG contour that needs manual triage.
///
/// Keys are stable [VisionCollisionGroup.id] values emitted by the calibration
/// overlay. An empty override set deliberately keeps the fail-safe behavior:
/// complete closed SVG contours block sight at every elevation.
class VisionGeometryOverrides {
  const VisionGeometryOverrides({
    this.attack = const {},
    this.defense = const {},
  });

  final Map<String, VisionCollisionOverride> attack;
  final Map<String, VisionCollisionOverride> defense;

  bool get isEmpty => attack.isEmpty && defense.isEmpty;

  VisionGeometryOverrides merge(VisionGeometryOverrides other) =>
      VisionGeometryOverrides(
        attack: Map.unmodifiable({...attack, ...other.attack}),
        defense: Map.unmodifiable({...defense, ...other.defense}),
      );

  factory VisionGeometryOverrides.fromJson(
    MapValue map,
    Map<String, dynamic> json,
  ) {
    _validateKeys(json, const {'version', 'maps'}, 'override root');
    if (json['version'] != 1) {
      throw const FormatException(
        'Unsupported vision contour override version.',
      );
    }
    final maps = json['maps'];
    if (maps is! Map<String, dynamic>) {
      throw const FormatException('Vision contour overrides maps is invalid.');
    }
    final knownMapNames = Maps.mapNames.values.toSet();
    for (final entry in maps.entries) {
      if (!knownMapNames.contains(entry.key)) {
        throw FormatException(
          'Unknown map in contour overrides: ${entry.key}.',
        );
      }
      if (entry.value is! Map<String, dynamic>) {
        throw FormatException('Invalid contour overrides for ${entry.key}.');
      }
    }
    final mapValue = maps[Maps.mapNames[map]];
    if (mapValue == null) return const VisionGeometryOverrides();
    if (mapValue is! Map<String, dynamic>) {
      throw FormatException('Invalid contour overrides for ${map.name}.');
    }
    _validateKeys(mapValue, const {
      'attack',
      'defense',
    }, '${map.name} overrides');
    return VisionGeometryOverrides(
      attack: _decodeCollisionOverrides(mapValue['attack'], map),
      defense: _decodeCollisionOverrides(mapValue['defense'], map),
    );
  }

  static Map<String, VisionCollisionOverride> _decodeCollisionOverrides(
    dynamic value,
    MapValue map,
  ) {
    if (value == null) return const {};
    if (value is! Map<String, dynamic>) {
      throw FormatException('Invalid contour side overrides for ${map.name}.');
    }
    return Map.unmodifiable({
      for (final entry in value.entries)
        entry.key: VisionCollisionOverride.fromJson(entry.value),
    });
  }

  static void _validateKeys(
    Map<String, dynamic> value,
    Set<String> allowed,
    String context,
  ) {
    final unknown = value.keys.where((key) => !allowed.contains(key)).toList();
    if (unknown.isNotEmpty) {
      throw FormatException('Unknown $context fields: ${unknown.join(', ')}.');
    }
  }
}

class VisionCollisionOverride {
  const VisionCollisionOverride({
    this.enabled,
    this.activeElevations,
    this.inactiveElevations = const [],
    this.observerPassableElevations,
  });

  final bool? enabled;
  final List<double>? activeElevations;
  final List<double> inactiveElevations;
  final List<double>? observerPassableElevations;

  factory VisionCollisionOverride.fromJson(dynamic value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid vision contour override.');
    }
    VisionGeometryOverrides._validateKeys(value, const {
      'enabled',
      'activeElevations',
      'inactiveElevations',
      'observerPassableElevations',
    }, 'contour override');
    final enabled = value['enabled'];
    if (enabled != null && enabled is! bool) {
      throw const FormatException('Contour enabled must be a boolean.');
    }
    final active = _decodeElevations(value, 'activeElevations');
    final inactive = _decodeElevations(value, 'inactiveElevations') ?? const [];
    if (active != null && active.any(inactive.contains)) {
      throw const FormatException(
        'Contour override has conflicting active/inactive elevations.',
      );
    }
    return VisionCollisionOverride(
      enabled: enabled as bool?,
      activeElevations: active,
      inactiveElevations: inactive,
      observerPassableElevations: _decodeElevations(
        value,
        'observerPassableElevations',
      ),
    );
  }

  static List<double>? _decodeElevations(
    Map<String, dynamic> value,
    String key,
  ) {
    final elevations = value[key];
    if (elevations == null) return null;
    if (elevations is! List || elevations.any((item) => item is! num)) {
      throw FormatException('$key must contain only numbers.');
    }
    return List<double>.unmodifiable(
      elevations.cast<num>().map((item) => item.toDouble()),
    );
  }
}

class _ContourLayerScore {
  const _ContourLayerScore({
    required this.strictCoverage,
    required this.broadCoverage,
    required this.riotIndices,
  });

  const _ContourLayerScore.empty()
    : strictCoverage = 0,
      broadCoverage = 0,
      riotIndices = const {};

  final double strictCoverage;
  final double broadCoverage;
  final Set<int> riotIndices;

  /// Whole-contour support must be strong at the tight tolerance. Broad
  /// coverage is diagnostic only; using it for admission recreated the false
  /// matches that split boxes and walls on Breeze.
  bool get isSupported => strictCoverage >= 0.60;
}

class VisionHeightSample {
  const VisionHeightSample({required this.position, required this.elevation});

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
    required this.maskSegments,
    required this.contours,
    required this.collisionGroups,
    required this.outerGroupId,
    required this.fillRule,
    this.alwaysOnSegments = const [],
  });

  /// Every exact SVG collision candidate, including structural details.
  final List<VisionSegment> segments;

  /// Only the base-fill edges used to decide whether an observer is on-map.
  final List<VisionSegment> maskSegments;
  final List<List<Offset>> contours;
  final List<VisionCollisionGroup> collisionGroups;
  final String outerGroupId;
  final VisionFillRule fillRule;
  final List<VisionSegment> alwaysOnSegments;

  VisionCollisionGroup get outerGroup =>
      collisionGroups.firstWhere((group) => group.id == outerGroupId);

  bool containsOuterFootprint(Offset point) => outerGroup.contains(point);

  bool contains(Offset point) {
    for (final segment in maskSegments) {
      if (_pointIsOnSegment(point, segment)) return true;
    }

    if (fillRule == VisionFillRule.evenOdd) {
      var inside = false;
      for (final segment in maskSegments) {
        final start = segment.start;
        final end = segment.end;
        if ((start.dy > point.dy) == (end.dy > point.dy)) continue;
        final intersectionX =
            start.dx +
            (point.dy - start.dy) * (end.dx - start.dx) / (end.dy - start.dy);
        if (intersectionX > point.dx) inside = !inside;
      }
      return inside;
    }

    var winding = 0;
    for (final segment in maskSegments) {
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
    this.collisionGroups = const [],
    this.observerGroups = const [],
    this.debugCollisionGroups = const [],
    this.layerIndex = 0,
    this.segmentIndex,
  });

  final double elevation;
  final List<VisionSegment> segments;
  final List<VisionSegment>? sourceSegments;
  final List<VisionSegment> matchedSourceSegments;
  final List<VisionSegment> matchedBoundarySegments;
  final List<VisionSegment> rejectedSegments;
  final List<VisionSegment> boundarySegments;
  final VisionBoundary? boundary;
  final List<VisionCollisionGroup> collisionGroups;
  final List<VisionCollisionGroup> observerGroups;
  final List<VisionCollisionGroup> debugCollisionGroups;
  final int layerIndex;
  final VisionSegmentIndex? segmentIndex;

  List<VisionSegment> get riotSegments => sourceSegments ?? segments;

  bool contains(Offset point) {
    final mask = boundary;
    if (mask == null || mask.contains(point)) return true;
    if (!mask.containsOuterFootprint(point)) return false;
    // A nested base-fill contour can be a real raised/walkable floor rather
    // than a void. Riot nav samples tell us when that is the case.
    return observerGroups.any(
      (group) =>
          !group.isOuterBoundary &&
          group.isClosed &&
          group.excludesObserverInLayer(layerIndex) &&
          group.contains(point),
    );
  }

  List<VisionSegment> segmentsForObserver(Offset origin, double range) {
    final indexes =
        segmentIndex?.queryBounds(
          Rect.fromCircle(center: origin, radius: range),
        ) ??
        [
          for (var index = 0; index < segments.length; index += 1)
            if (segments[index].intersectsRangeBounds(origin, range)) index,
        ];
    final excludedGroupIds = <String>{};
    for (final group in collisionGroups) {
      if (group.isOuterBoundary ||
          !group.isClosed ||
          !group.excludesObserverInLayer(layerIndex) ||
          !group.contains(origin)) {
        continue;
      }
      excludedGroupIds.add(group.id);
    }
    final excludedKeys = <String>{
      for (final group in collisionGroups)
        if (excludedGroupIds.contains(group.id))
          for (final segment in group.segments) visionSegmentKey(segment),
    };
    // A deduplicated runtime segment can be owned by more than one contour.
    // Keep it whenever any non-excluded owner still needs that wall.
    for (final group in collisionGroups) {
      if (excludedGroupIds.contains(group.id)) continue;
      excludedKeys.removeAll(group.segments.map(visionSegmentKey));
    }
    return List<VisionSegment>.unmodifiable([
      for (final index in indexes)
        if (segments[index].intersectsRangeBounds(origin, range) &&
            !excludedKeys.contains(visionSegmentKey(segments[index])))
          segments[index],
    ]);
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
    final candidateSegments = layer.segmentsForObserver(origin, safeRange);
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
