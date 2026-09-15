import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui';

import 'package:icarus/view_cone/vision_collision.dart';

/// A selected baked plane owns only its four endpoint coordinates per edge.
/// Ray queries read those numbers directly; endpoint event queries materialize
/// ordinary segments only when they intersect the observer's range.
class VisionWorldSegments extends ListBase<VisionSegment> {
  VisionWorldSegments.fromQuantized({
    required Int32List vertices,
    required Int32List edges,
    required Int32List layerEdges,
    required double coordinateScale,
    required Offset uvUnitsPerMeter,
  })  : _coordinates = Float64List(layerEdges.length * 4),
        _materialized = List<VisionSegment?>.filled(layerEdges.length, null) {
    for (var index = 0; index < layerEdges.length; index++) {
      final edge = layerEdges[index] * 2;
      final a = edges[edge] * 2;
      final b = edges[edge + 1] * 2;
      final offset = index * 4;
      _coordinates[offset] = vertices[a] / coordinateScale / uvUnitsPerMeter.dx;
      _coordinates[offset + 1] =
          vertices[a + 1] / coordinateScale / uvUnitsPerMeter.dy;
      _coordinates[offset + 2] =
          vertices[b] / coordinateScale / uvUnitsPerMeter.dx;
      _coordinates[offset + 3] =
          vertices[b + 1] / coordinateScale / uvUnitsPerMeter.dy;
      for (var ordinate = 0; ordinate < 4; ordinate++) {
        if (!_coordinates[offset + ordinate].isFinite) {
          throw const FormatException('Non-finite world vertex projection.');
        }
      }
    }
  }

  final Float64List _coordinates;
  final List<VisionSegment?> _materialized;

  double coordinate(int segment, int ordinate) =>
      _coordinates[segment * 4 + ordinate];

  @override
  int get length => _materialized.length;

  @override
  set length(int value) => throw UnsupportedError('Baked edges are immutable.');

  @override
  VisionSegment operator [](int index) =>
      _materialized[index] ??= VisionSegment.unthickened(
        Offset(coordinate(index, 0), coordinate(index, 1)),
        Offset(coordinate(index, 2), coordinate(index, 3)),
      );

  @override
  void operator []=(int index, VisionSegment value) =>
      throw UnsupportedError('Baked edges are immutable.');
}
