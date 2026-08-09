import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/svg_vision_boundary.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

import 'vision_geometry_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SvgVisionBoundary', () {
    test('preserves open chains without inventing closing diagonals', () {
      const source = '''
<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <path fill="#271406" d="M5 5H95V95H5Z"/>
  <path stroke="#B27C40" d="M20 20H40V40 M60 20H80V40H60Z"/>
</svg>
''';
      final boundary = SvgVisionBoundary.parse(
        map: MapValue.ascent,
        source: source,
      );
      final open = boundary.collisionGroups.singleWhere(
        (group) => group.kind == VisionCollisionKind.structuralChain,
      );
      final closed = boundary.collisionGroups.singleWhere(
        (group) => group.kind == VisionCollisionKind.structuralObstacle,
      );

      expect(open.isClosed, isFalse);
      expect(open.points, hasLength(3));
      expect(open.segments, hasLength(2));
      expect(
        open.segments.any(
          (segment) =>
              (segment.start - open.points.last).distance < 0.001 &&
              (segment.end - open.points.first).distance < 0.001,
        ),
        isFalse,
        reason: 'an open L must not gain a phantom diagonal',
      );
      expect(closed.isClosed, isTrue);
      expect(closed.points.first, closed.points.last);
      expect(closed.segments, hasLength(4));
    });

    test('extracts structural primitives and flags thin or faint details', () {
      const source = '''
<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <path fill="#271406" d="M5 5H95V95H5Z"/>
  <circle cx="20" cy="20" r="5" stroke="#B27C40"/>
  <rect x="30" y="10" width="10" height="20" stroke="#B27C40"/>
  <line x1="50" y1="10" x2="50" y2="30" stroke="#B27C40"/>
  <rect x="60" y="10" width="10" height="20" stroke="#B27C40"
      stroke-width="0.5"/>
  <circle cx="85" cy="20" r="5" stroke="#B27C40"
      stroke-opacity="0.25"/>
</svg>
''';
      final boundary = SvgVisionBoundary.parse(
        map: MapValue.ascent,
        source: source,
      );
      final details = boundary.collisionGroups
          .where((group) => group.kind != VisionCollisionKind.maskBoundary)
          .toList();

      expect(details, hasLength(5));
      expect(details[0].isClosed, isTrue);
      expect(details[0].segments, hasLength(32));
      expect(details[0].requiresEvidence, isFalse);
      expect(details[1].isClosed, isTrue);
      expect(details[1].segments, hasLength(4));
      expect(details[1].requiresEvidence, isFalse);
      expect(details[2].kind, VisionCollisionKind.structuralChain);
      expect(details[2].segments, hasLength(1));
      expect(details[2].requiresEvidence, isFalse);
      expect(details[3].isClosed, isTrue);
      expect(details[3].requiresEvidence, isTrue);
      expect(details[4].isClosed, isTrue);
      expect(details[4].requiresEvidence, isTrue);
    });

    test('reconstructs split cycles only within one structural path', () {
      const source = '''
<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <path fill="#271406" d="M5 5H95V95H5Z"/>
  <path stroke="#B27C40"
      d="M20 20H40V40 M40.0004 40.0003H20V20.0002 M20 20H10"/>
  <path stroke="#B27C40" d="M60 20H80V40"/>
  <path stroke="#B27C40" d="M80 40H60V20"/>
</svg>
''';
      final boundary = SvgVisionBoundary.parse(
        map: MapValue.ascent,
        source: source,
      );
      final details = boundary.collisionGroups
          .where((group) => group.kind != VisionCollisionKind.maskBoundary)
          .toList();
      final obstacles = details
          .where(
            (group) => group.kind == VisionCollisionKind.structuralObstacle,
          )
          .toList();
      final chains = details
          .where(
            (group) => group.kind == VisionCollisionKind.structuralChain,
          )
          .toList();

      expect(obstacles, hasLength(1));
      expect(obstacles.single.isClosed, isFalse);
      expect(obstacles.single.paths, hasLength(2));
      expect(obstacles.single.segments, hasLength(4));
      expect(chains, hasLength(3));
      expect(
        chains.map((group) => group.segments.length),
        unorderedEquals([1, 2, 2]),
        reason: 'one-ended and cross-element chains must not join the cycle',
      );
      expect(
        details.expand((group) => group.segments).any(
              (segment) => segment.length < 0.01,
            ),
        isFalse,
        reason: 'tight endpoint snapping must not add a synthetic ray edge',
      );
    });

    test('split cycles keep thin-stroke evidence requirements', () {
      const source = '''
<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <path fill="#271406" d="M5 5H95V95H5Z"/>
  <path stroke="#B27C40" stroke-width="0.5"
      d="M20 20H40V40 M40 40H20V20"/>
</svg>
''';
      final boundary = SvgVisionBoundary.parse(
        map: MapValue.ascent,
        source: source,
      );
      final obstacles = boundary.collisionGroups.where(
        (group) => group.kind == VisionCollisionKind.structuralObstacle,
      );

      expect(obstacles, hasLength(1));
      expect(obstacles.single.paths, hasLength(2));
      expect(obstacles.single.requiresEvidence, isTrue);
    });

    test('uses a closed mask contour to complete a structural cycle', () {
      const source = '''
<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <path fill="#271406" d="M5 5H95V95H5Z"/>
  <path stroke="#B27C40"
      d="M5 20H20V30V40H5 M20 30H30"/>
</svg>
''';
      final boundary = SvgVisionBoundary.parse(
        map: MapValue.ascent,
        source: source,
      );
      final details = boundary.collisionGroups
          .where((group) => group.kind != VisionCollisionKind.maskBoundary)
          .toList();
      final obstacle = details.singleWhere(
        (group) => group.kind == VisionCollisionKind.structuralObstacle,
      );
      final tail = details.singleWhere(
        (group) => group.kind == VisionCollisionKind.structuralChain,
      );

      expect(obstacle.paths, hasLength(1));
      expect(obstacle.segments, hasLength(4));
      expect(tail.segments, hasLength(1));
      expect(
        details.expand((group) => group.segments),
        hasLength(5),
        reason: 'the mask is topology-only and must not add connector edges',
      );
    });

    test('closes at an authored interior vertex and preserves bridge tails',
        () {
      const source = '''
<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <path fill="#271406" d="M5 5H95V95H5Z"/>
  <path stroke="#B27C40"
      d="M20 20H40V40H20 M20 50V40V20V10"/>
</svg>
''';
      final boundary = SvgVisionBoundary.parse(
        map: MapValue.ascent,
        source: source,
      );
      final details = boundary.collisionGroups
          .where((group) => group.kind != VisionCollisionKind.maskBoundary)
          .toList();
      final compound = details.singleWhere(
        (group) => group.kind == VisionCollisionKind.structuralObstacle,
      );
      final tails = details
          .where((group) => group.kind == VisionCollisionKind.structuralChain)
          .toList();

      expect(compound.paths, hasLength(2));
      expect(compound.segments, hasLength(4));
      expect(tails, hasLength(2));
      expect(tails.every((group) => group.segments.length == 1), isTrue);
      expect(
        details.expand((group) => group.segments),
        hasLength(6),
        reason: 'the six authored segments must neither disappear nor grow',
      );
    });

    test('compound IDs ignore sibling path order and orientation', () {
      const first = <Offset>[
        Offset(20, 20),
        Offset(40, 20),
        Offset(40, 40),
      ];
      const second = <Offset>[
        Offset(40, 40),
        Offset(20, 40),
        Offset(20, 20),
      ];
      final forward = VisionCollisionGroup.compoundGeometry(
        paths: const [first, second],
        kind: VisionCollisionKind.structuralObstacle,
      );
      final reordered = VisionCollisionGroup.compoundGeometry(
        paths: [second.reversed.toList(), first.reversed.toList()],
        kind: VisionCollisionKind.structuralObstacle,
      );

      expect(reordered.id, forward.id);
      expect(
        segmentKeys(reordered.segments),
        segmentKeys(forward.segments),
      );
    });
  });
}
