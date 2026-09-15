import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/vision_world_index.dart';
import 'package:icarus/view_cone/vision_world_segments.dart';

void main() {
  test('ordered trees retain every edge across uneven median subdivisions', () {
    for (var count = 0; count <= 257; count++) {
      final packed = VisionWorldSegments.fromQuantized(
        vertices: Int32List.fromList([
          for (var i = 0; i < count; i++) ...[i + 1, -1, i + 1, 1],
        ]),
        edges: Int32List.fromList(List.generate(count * 2, (i) => i)),
        layerEdges: Int32List.fromList(List.generate(count, (i) => i)),
        coordinateScale: 1,
        uvUnitsPerMeter: const Offset(1, 1),
      );
      final index = VisionWorldIndex(packed, spatiallyOrdered: true);
      final visited = <double>[];
      index.visitConeSegments(
        origin: Offset.zero,
        facingAngle: 0,
        coneAngle: math.pi,
        range: 300,
        visit: (ax, ay, bx, by) => visited.add(ax),
      );
      expect(visited, [for (var i = 0; i < count; i++) i + 1],
          reason: 'Lost, duplicated or reordered an edge with count=$count.');
      int? edge;
      final hit = index.nearestHit(
        origin: Offset.zero,
        direction: const Offset(1, 0),
        range: 300,
        onNearestEdge: (value) => edge = value,
      );
      expect(hit, count == 0 ? isNull : 1);
      expect(edge, count == 0 ? isNull : 0);
    }
  });
}
