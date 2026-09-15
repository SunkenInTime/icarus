import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/vision_collision.dart';
import 'package:icarus/view_cone/vision_world_index.dart';
import 'package:icarus/view_cone/vision_world_segments.dart';

class _CountingSegments extends VisionWorldSegments {
  _CountingSegments(Int32List vertices)
      : super.fromQuantized(
          vertices: vertices,
          edges: Int32List.fromList(
              List.generate(vertices.length ~/ 2, (index) => index)),
          layerEdges: Int32List.fromList(
              List.generate(vertices.length ~/ 4, (index) => index)),
          coordinateScale: 1000,
          uvUnitsPerMeter: const Offset(.5, 2),
        );

  var reads = 0;

  @override
  VisionSegment operator [](int index) {
    reads++;
    return super[index];
  }
}

void main() {
  test('coordinate visitor keeps exact candidate order without segment objects',
      () {
    final random = math.Random(791917);
    final packed = _CountingSegments(Int32List.fromList([
      for (var i = 0; i < 1200; i++) random.nextInt(20000) - 10000,
    ]));
    final index = VisionWorldIndex(packed, spatiallyOrdered: true);
    expect(packed.reads, 0);
    for (var i = 0; i < 300; i++) {
      final origin =
          Offset(random.nextDouble() * 40 - 20, random.nextDouble() * 20 - 10);
      final facing = random.nextDouble() * 20 - 10;
      final cone =
          [0.0, math.pi / 2, math.pi, math.pi * 1.5, math.pi * 2][i % 5];
      final range = i % 10 == 0 ? 0.0 : random.nextDouble() * 30;
      final actual = <List<double>>[];
      final readsBefore = packed.reads;
      index.visitConeSegments(
        origin: origin,
        facingAngle: facing,
        coneAngle: cone,
        range: range,
        visit: (ax, ay, bx, by) => actual.add([ax, ay, bx, by]),
      );
      expect(packed.reads, readsBefore,
          reason: 'The coordinate path must not materialize packed segments.');
      final expected = index
          .queryCone(
              origin: origin,
              facingAngle: facing,
              coneAngle: cone,
              range: range)
          .map((edge) =>
              [edge.start.dx, edge.start.dy, edge.end.dx, edge.end.dy])
          .toList();
      expect(actual, expected);
    }
  });

  test('coordinate visitor preserves crossing and boundary-touching edges', () {
    final index = VisionWorldIndex([
      VisionSegment.unthickened(const Offset(2, -10), const Offset(2, 10)),
      VisionSegment.unthickened(const Offset(-2, -1), const Offset(-2, 1)),
      VisionSegment.unthickened(const Offset(1, 1), const Offset(3, 3)),
      VisionSegment.unthickened(const Offset(20, -1), const Offset(20, 1)),
    ]);
    final actual = <List<double>>[];
    index.visitConeSegments(
      origin: Offset.zero,
      facingAngle: 0,
      coneAngle: math.pi / 2,
      range: 20,
      visit: (ax, ay, bx, by) => actual.add([ax, ay, bx, by]),
    );
    expect(actual, [
      [2, -10, 2, 10],
      [1, 1, 3, 3],
      [20, -1, 20, 1],
    ]);
  });
}
