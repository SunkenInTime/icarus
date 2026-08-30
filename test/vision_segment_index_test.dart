import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

import 'vision_geometry_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VisionSegmentIndex', () {
    test('indexes the full visible wall stroke envelope', () {
      final segment = VisionSegment(
        const Offset(10, 0),
        const Offset(10, 20),
        collisionRadius: 2,
      );
      final index = VisionSegmentIndex([segment], cellSize: 5);

      expect(
        index.queryBounds(const Rect.fromLTRB(11.5, 8, 12, 12)),
        [0],
      );
    });

    test('matches brute-force segment bounding-box candidates', () {
      final segments = <VisionSegment>[
        VisionSegment(const Offset(-25, -5), const Offset(-15, 5)),
        VisionSegment(const Offset(0, 0), const Offset(9, 9)),
        VisionSegment(const Offset(12, 2), const Offset(18, 8)),
        VisionSegment(const Offset(25, -20), const Offset(25, 20)),
        VisionSegment(const Offset(41, 41), const Offset(45, 45)),
        VisionSegment(const Offset(9.5, 50), const Offset(10.5, 50)),
      ];
      final index = VisionSegmentIndex(segments, cellSize: 10);
      final queries = <Rect>[
        const Rect.fromLTRB(-30, -10, -20, 0),
        const Rect.fromLTRB(-19, 6, -16, 9),
        const Rect.fromLTRB(1, 1, 2, 2),
        const Rect.fromLTRB(10, 0, 20, 10),
        const Rect.fromLTRB(24, -1, 26, 1),
        const Rect.fromLTRB(39, 39, 42, 42),
        const Rect.fromLTRB(10, 49, 10, 51),
        const Rect.fromLTRB(100, 100, 110, 110),
      ];

      for (final query in queries) {
        final bruteForce = <int>[
          for (var candidate = 0; candidate < segments.length; candidate += 1)
            if (segmentBoundsOverlap(segments[candidate], query)) candidate,
        ];
        expect(
          index.queryBounds(query),
          bruteForce,
          reason: query.toString(),
        );
      }
    });
  });

  test('legacy widget offsets round-trip through normalized world space', () {
    CoordinateSystem(playAreaSize: const Size(1600, 900));
    const virtualOffset = Offset(300, 307.5);
    final coordinateSystem = CoordinateSystem.instance;
    final worldOffset = coordinateSystem.virtualOffsetToWorld(virtualOffset);

    expect(
      coordinateSystem.worldOffsetToScreen(worldOffset).dx,
      closeTo(coordinateSystem.scale(virtualOffset.dx), 1e-9),
    );
    expect(
      coordinateSystem.worldOffsetToScreen(worldOffset).dy,
      closeTo(coordinateSystem.scale(virtualOffset.dy), 1e-9),
    );
    expect(
      coordinateSystem.virtualLengthToWorld(50),
      closeTo(50 * 1000 / 831, 1e-9),
    );
  });
}
