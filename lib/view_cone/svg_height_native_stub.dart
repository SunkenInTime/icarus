import 'dart:typed_data';
import 'dart:ui';

class SvgHeightNativeStats {
  const SvgHeightNativeStats({
    required this.rayCount,
    required this.edgeTests,
    required this.spatialNodes,
    required this.candidateEdges,
    required this.preparationMicros,
    required this.candidateMicros,
    required this.queryMicros,
  });

  final int rayCount;
  final int edgeTests;
  final int spatialNodes;
  final int candidateEdges;
  final double preparationMicros;
  final double candidateMicros;
  final double queryMicros;
}

class SvgHeightNativeCone {
  const SvgHeightNativeCone(this.xy, this.stats);

  /// Copied XY doubles. The first pair is the origin.
  final Float64List xy;
  final SvgHeightNativeStats stats;

  int get rayCount => stats.rayCount;
  int get edgeTests => stats.edgeTests;
  int get spatialNodes => stats.spatialNodes;
  int get candidateEdges => stats.candidateEdges;
  double get preparationMicros => stats.preparationMicros;
  double get candidateMicros => stats.candidateMicros;
  double get queryMicros => stats.queryMicros;
}

/// Web uses the visibility model's Dart ray caster.
class SvgHeightNative {
  static SvgHeightNative? tryOpen(
          {required List<String> wallIds,
          required Float64List edgeRecords,
          String? libraryPath}) =>
      null;
  SvgHeightNativeCone query(
          {required Offset origin,
          required double directionRadians,
          required double range,
          required double apertureRadians,
          required List<bool> activeWalls,
          int arcSteps = 96}) =>
      throw UnsupportedError('Native acceleration is unavailable on web.');
  void close() {}
}
