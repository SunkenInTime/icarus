import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/page_transition/agent_path.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

void main() {
  group('AgentTransitionPath', () {
    test('samples by traveled distance instead of waypoint count', () {
      final path = AgentTransitionPath(const [
        Offset(0, 0),
        Offset(10, 0),
        Offset(10, 30),
      ]);

      expect(path.length, 40);
      expect(path.positionAt(0.5), const Offset(10, 10));
    });

    test('clamps progress to both ends', () {
      final path = AgentTransitionPath(const [Offset(2, 3), Offset(8, 9)]);

      expect(path.positionAt(-1), const Offset(2, 3));
      expect(path.positionAt(2), const Offset(8, 9));
    });
  });

  test('A* routes around view-cone collision segments', () {
    final outer = VisionCollisionGroup.geometry(
      id: 'outer',
      points: const [
        Offset(0, 0),
        Offset(120, 0),
        Offset(120, 120),
        Offset(0, 120),
      ],
      kind: VisionCollisionKind.maskBoundary,
      isClosed: true,
      isOuterBoundary: true,
    );
    final wall = VisionCollisionGroup.geometry(
      id: 'wall',
      points: const [Offset(60, 0), Offset(60, 85)],
      kind: VisionCollisionKind.structuralChain,
      isClosed: false,
    );
    final boundary = VisionBoundary(
      segments: [...outer.segments, ...wall.segments],
      maskSegments: outer.segments,
      contours: [outer.points],
      collisionGroups: [outer, wall],
      outerGroupId: outer.id,
      fillRule: VisionFillRule.nonZero,
    );
    final segments = [...outer.segments, ...wall.segments];
    final layer = VisionGeometryLayer(
      elevation: 0,
      segments: segments,
      boundary: boundary,
      collisionGroups: [outer, wall],
      segmentIndex: VisionSegmentIndex(segments, cellSize: 16),
    );

    const pathfinder = AgentTransitionPathfinder(gridSpacing: 10, clearance: 2);
    final path = pathfinder.findPath(
      start: const Offset(20, 30),
      end: const Offset(100, 30),
      layer: layer,
    );

    expect(path.points.length, greaterThan(2));
    expect(path.points.any((point) => point.dy > 85), isTrue);
    expect(path.positionAt(0), const Offset(20, 30));
    expect(path.positionAt(1), const Offset(100, 30));
  });

  test('smoothed paths preserve clearance from wall corners', () {
    final outer = VisionCollisionGroup.geometry(
      id: 'outer',
      points: const [
        Offset(0, 0),
        Offset(120, 0),
        Offset(120, 120),
        Offset(0, 120),
      ],
      kind: VisionCollisionKind.maskBoundary,
      isClosed: true,
      isOuterBoundary: true,
    );
    final wall = VisionCollisionGroup.geometry(
      id: 'nearby-wall',
      points: const [Offset(60, 53), Offset(60, 90)],
      kind: VisionCollisionKind.structuralChain,
      isClosed: false,
    );
    final boundary = VisionBoundary(
      segments: [...outer.segments, ...wall.segments],
      maskSegments: outer.segments,
      contours: [outer.points],
      collisionGroups: [outer, wall],
      outerGroupId: outer.id,
      fillRule: VisionFillRule.nonZero,
    );
    final segments = [...outer.segments, ...wall.segments];
    final layer = VisionGeometryLayer(
      elevation: 0,
      segments: segments,
      boundary: boundary,
      segmentIndex: VisionSegmentIndex(segments, cellSize: 16),
    );

    const pathfinder = AgentTransitionPathfinder(
      gridSpacing: 10,
      clearance: 5,
    );
    final path = pathfinder.findPath(
      start: const Offset(20, 50),
      end: const Offset(100, 50),
      layer: layer,
    );

    expect(path.points.length, greaterThan(2));
    expect(path.points.any((point) => point.dy <= 40), isTrue);
  });
}
