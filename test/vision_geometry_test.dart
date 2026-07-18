import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/svg_vision_boundary.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

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
        _segmentKeys(reordered.segments),
        _segmentKeys(forward.segments),
      );
    });
  });

  group('VisionGeometryMap', () {
    test('loads the generated Ascent slices and default elevation', () async {
      final source = await rootBundle.loadString(
        'assets/maps/ascent_vision.json',
      );
      final geometry = VisionGeometryMap.fromCompactJson(
        MapValue.ascent,
        jsonDecode(source) as Map<String, dynamic>,
      );

      expect(geometry.attackLayers, hasLength(8));
      expect(geometry.defaultElevation, 300);
      expect(geometry.layerFor(isAttack: true).elevation, 300);
      expect(
        geometry.layerFor(isAttack: true, elevation: 810).elevation,
        800,
      );
      expect(
        geometry.attackLayers.expand((layer) => layer.segments),
        isNotEmpty,
      );
    });

    test('uses exact SVG groups as the only runtime collision geometry',
        () async {
      final source = await rootBundle.loadString(
        'assets/maps/ascent_vision.json',
      );
      final svg = await rootBundle.loadString('assets/maps/ascent_map.svg');
      final defenseSvg = await rootBundle.loadString(
        'assets/maps/ascent_map_defense.svg',
      );
      final geometry = VisionGeometryMap.fromCompactJson(
        MapValue.ascent,
        jsonDecode(source) as Map<String, dynamic>,
      ).withSvgBoundaries(
        attackBoundary: SvgVisionBoundary.parse(
          map: MapValue.ascent,
          source: svg,
        ),
        defenseBoundary: SvgVisionBoundary.parse(
          map: MapValue.ascent,
          source: defenseSvg,
        ),
      );

      expect(geometry.attackLayers, hasLength(8));
      expect(geometry.elevations, containsAll(<double>[300, 800]));
      expect(
        geometry.attackLayers.expand((layer) => layer.matchedSourceSegments),
        isNotEmpty,
      );
      expect(
        geometry.attackLayers.expand((layer) => layer.matchedBoundarySegments),
        isNotEmpty,
      );
      for (final layer in geometry.attackLayers) {
        expect(layer.sourceSegments, isEmpty);
        expect(layer.riotSegments, isEmpty);
        expect(layer.boundarySegments, isNotEmpty);
        expect(
            _segmentKeys(layer.segments), _segmentKeys(layer.boundarySegments));
        expect(
          _segmentKeys(layer.segments),
          _segmentKeys(layer.collisionGroups.expand((group) => group.segments)),
        );
        for (final group in layer.collisionGroups) {
          expect(
            _segmentKeys(layer.segments),
            containsAll(_segmentKeys(group.segments)),
            reason: '${group.id} must be present atomically',
          );
        }
        expect(layer.boundary, isNotNull);
      }
    });

    test('keeps closed SVG objects complete on every layer', () {
      const source = '''
<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <path fill="#271406" fill-rule="evenodd" d="M5 5H95V95H5Z"/>
  <path stroke="#B27C40" d="M20 20H40V40 M60 20H80V40H60Z"/>
</svg>
''';
      final boundary = SvgVisionBoundary.parse(
        map: MapValue.ascent,
        source: source,
      );
      final geometry = VisionGeometryMap.fromCompactJson(
        MapValue.ascent,
        <String, dynamic>{
          'version': 2,
          'map': 'ascent',
          'coordinateScale': 65536,
          'defaultElevation': 0,
          'observerHeight': 100,
          'heightSamples': <int>[],
          'layers': <Map<String, dynamic>>[
            <String, dynamic>{
              'elevation': 0,
              'vertices': <int>[],
              'edges': <int>[],
            },
            <String, dynamic>{
              'elevation': 500,
              'vertices': <int>[],
              'edges': <int>[],
            },
          ],
        },
      ).withSvgBoundaries(
        attackBoundary: boundary,
        defenseBoundary: boundary,
      );
      final closedDetail = boundary.collisionGroups.singleWhere(
        (group) =>
            group.kind == VisionCollisionKind.structuralObstacle &&
            group.isClosed,
      );
      final openDetail = boundary.collisionGroups.singleWhere(
        (group) => group.kind == VisionCollisionKind.structuralChain,
      );

      for (final layer in geometry.attackLayers) {
        expect(
          layer.collisionGroups.map((group) => group.id),
          contains(closedDetail.id),
        );
        expect(
          _segmentKeys(layer.segments),
          containsAll(_segmentKeys(closedDetail.segments)),
        );
        expect(
          layer.collisionGroups.map((group) => group.id),
          isNot(contains(openDetail.id)),
          reason: 'unsupported open SVG chains must not become walls',
        );
      }
    });

    test('admits or rejects a thin split cycle as one runtime group', () {
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
      final compound = boundary.collisionGroups.singleWhere(
        (group) => group.kind == VisionCollisionKind.structuralObstacle,
      );
      final rejected = _oneLayerGeometry(MapValue.ascent).withSvgBoundaries(
        attackBoundary: boundary,
        defenseBoundary: boundary,
      );
      final admitted = _oneLayerGeometry(MapValue.ascent).withSvgBoundaries(
        attackBoundary: boundary,
        defenseBoundary: boundary,
        overrides: VisionGeometryOverrides(
          attack: {
            compound.id: const VisionCollisionOverride(enabled: true),
          },
        ),
      );

      expect(compound.paths, hasLength(2));
      expect(compound.segments, hasLength(4));
      expect(
        rejected.attackLayers.single.collisionGroups.map((group) => group.id),
        isNot(contains(compound.id)),
      );
      final active = admitted.attackLayers.single.collisionGroups.singleWhere(
        (group) => group.id == compound.id,
      );
      expect(active.overrideApplied, isTrue);
      expect(
        _segmentKeys(admitted.attackLayers.single.segments),
        containsAll(_segmentKeys(compound.segments)),
      );
    });

    test('rejects outer, unknown-contour, and unknown-elevation overrides', () {
      final boundary = _overrideTestBoundary();
      final geometry = _twoLayerAscentGeometry();
      final interior = boundary.collisionGroups.singleWhere(
        (group) => group.kind == VisionCollisionKind.structuralObstacle,
      );

      expect(
        () => geometry.withSvgBoundaries(
          attackBoundary: boundary,
          defenseBoundary: boundary,
          overrides: VisionGeometryOverrides(
            attack: {
              boundary.outerGroupId:
                  const VisionCollisionOverride(enabled: false),
            },
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => geometry.withSvgBoundaries(
          attackBoundary: boundary,
          defenseBoundary: boundary,
          overrides: const VisionGeometryOverrides(
            attack: {
              'does_not_exist': VisionCollisionOverride(enabled: true),
            },
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => geometry.withSvgBoundaries(
          attackBoundary: boundary,
          defenseBoundary: boundary,
          overrides: VisionGeometryOverrides(
            attack: {
              interior.id: const VisionCollisionOverride(
                activeElevations: [12345],
              ),
            },
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects malformed contour override schemas', () {
      final malformed = <Map<String, dynamic>>[
        <String, dynamic>{'version': 2, 'maps': <String, dynamic>{}},
        <String, dynamic>{
          'version': 1,
          'maps': <String, dynamic>{},
          'unexpected': true,
        },
        <String, dynamic>{
          'version': 1,
          'maps': <String, dynamic>{'unknown_map': <String, dynamic>{}},
        },
        <String, dynamic>{
          'version': 1,
          'maps': <String, dynamic>{
            'ascent': <String, dynamic>{'unexpected': true},
          },
        },
        <String, dynamic>{
          'version': 1,
          'maps': <String, dynamic>{
            'ascent': <String, dynamic>{'attack': <dynamic>[]},
          },
        },
        <String, dynamic>{
          'version': 1,
          'maps': <String, dynamic>{
            'ascent': <String, dynamic>{
              'attack': <String, dynamic>{
                'id': <String, dynamic>{'unexpected': true},
              },
            },
          },
        },
        <String, dynamic>{
          'version': 1,
          'maps': <String, dynamic>{
            'ascent': <String, dynamic>{
              'attack': <String, dynamic>{
                'id': <String, dynamic>{'enabled': 'yes'},
              },
            },
          },
        },
        <String, dynamic>{
          'version': 1,
          'maps': <String, dynamic>{
            'ascent': <String, dynamic>{
              'attack': <String, dynamic>{
                'id': <String, dynamic>{
                  'activeElevations': <dynamic>['high'],
                },
              },
            },
          },
        },
        <String, dynamic>{
          'version': 1,
          'maps': <String, dynamic>{
            'ascent': <String, dynamic>{
              'attack': <String, dynamic>{
                'id': <String, dynamic>{
                  'activeElevations': <num>[0],
                  'inactiveElevations': <num>[0],
                },
              },
            },
          },
        },
      ];

      for (final json in malformed) {
        expect(
          () => VisionGeometryOverrides.fromJson(MapValue.ascent, json),
          throwsA(isA<FormatException>()),
          reason: json.toString(),
        );
      }
    });

    test('does not admit unsupported open chains on Summit', () {
      const source = '''
<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <path fill="#271406" d="M5 5H95V95H5Z"/>
  <path stroke="#B27C40" d="M20 20H80"/>
  <path stroke="#B27C40" d="M30 30H40V40H30Z"/>
</svg>
''';
      final boundary = SvgVisionBoundary.parse(
        map: MapValue.summit,
        source: source,
      );
      final openGroup = boundary.collisionGroups.singleWhere(
        (group) => group.kind == VisionCollisionKind.structuralChain,
      );
      final closedGroup = boundary.collisionGroups.singleWhere(
        (group) => group.kind == VisionCollisionKind.structuralObstacle,
      );
      final geometry = _oneLayerGeometry(MapValue.summit).withSvgBoundaries(
        attackBoundary: boundary,
        defenseBoundary: boundary,
      );
      final activeIds = geometry.attackLayers.single.collisionGroups
          .map((group) => group.id)
          .toSet();

      expect(activeIds, isNot(contains(openGroup.id)));
      expect(activeIds, contains(closedGroup.id));
    });

    test('infers elevation from navigation height samples', () {
      final geometry = VisionGeometryMap.fromCompactJson(
        MapValue.ascent,
        <String, dynamic>{
          'version': 2,
          'map': 'ascent',
          'coordinateScale': 65536,
          'defaultElevation': 300,
          'observerHeight': 100,
          'heightSamples': <int>[32768, 32768, 500],
          'layers': <Map<String, dynamic>>[
            <String, dynamic>{
              'elevation': 300,
              'vertices': <int>[],
              'edges': <int>[],
            },
            <String, dynamic>{
              'elevation': 600,
              'vertices': <int>[],
              'edges': <int>[],
            },
          ],
        },
      );
      final samplePosition = geometry.heightField!.samples.single.position;

      expect(
        geometry.inferredHeightAt(
          isAttack: true,
          position: samplePosition,
        ),
        600,
      );
      expect(
        geometry
            .layerForPosition(
              isAttack: true,
              position: samplePosition,
            )
            .elevation,
        600,
      );
      expect(
        geometry
            .layerForPosition(
              isAttack: true,
              position: samplePosition,
              elevationOverride: 300,
            )
            .elevation,
        300,
      );
    });

    test('chooses the topmost co-located navigation surface', () {
      const field = VisionHeightField(<VisionHeightSample>[
        VisionHeightSample(position: Offset.zero, elevation: 100),
        VisionHeightSample(position: Offset(3, 0), elevation: 600),
        VisionHeightSample(position: Offset(20, 0), elevation: 1200),
      ]);

      expect(field.heightAt(const Offset(0.1, 0)), 600);
    });

    test('mirrors navigation passability evidence for defense geometry',
        () async {
      final attackSvg = await rootBundle.loadString(
        'assets/maps/breeze_map.svg',
      );
      final defenseSvg = await rootBundle.loadString(
        'assets/maps/breeze_map_defense.svg',
      );
      final attackBoundary = SvgVisionBoundary.parse(
        map: MapValue.breeze,
        source: attackSvg,
      );
      final defenseBoundary = SvgVisionBoundary.parse(
        map: MapValue.breeze,
        source: defenseSvg,
      );
      final geometry = _twoLayerBreezeGeometry(
        heightSamples: [
          ..._breezeHeightSample(350, 215, 400),
          ..._breezeHeightSample(360, 225, 400),
        ],
      ).withSvgBoundaries(
        attackBoundary: attackBoundary,
        defenseBoundary: defenseBoundary,
      );
      final attackSourceGroup = _groupNearBounds(
        attackBoundary,
        const Rect.fromLTRB(1144.6, 443.6, 1200.8, 498.7),
      );
      final defenseSourceGroup = _groupNearBounds(
        defenseBoundary,
        const Rect.fromLTRB(577, 501.3, 633.2, 556.4),
      );
      final attackGroup = geometry.attackLayers.last.collisionGroups
          .singleWhere((group) => group.id == attackSourceGroup.id);
      final defenseGroup = geometry.defenseLayers.last.collisionGroups
          .singleWhere((group) => group.id == defenseSourceGroup.id);

      expect(attackGroup.excludesObserverInLayer(1), isTrue);
      expect(defenseGroup.excludesObserverInLayer(1), isTrue);
      expect(attackGroup.navigationLayerMask, defenseGroup.navigationLayerMask);
    });

    test('only the topmost co-located navigation surface grants passability',
        () async {
      final attackSvg = await rootBundle.loadString(
        'assets/maps/breeze_map.svg',
      );
      final defenseSvg = await rootBundle.loadString(
        'assets/maps/breeze_map_defense.svg',
      );
      final attackBoundary = SvgVisionBoundary.parse(
        map: MapValue.breeze,
        source: attackSvg,
      );
      final geometry = _twoLayerBreezeGeometry(
        heightSamples: [
          ..._breezeHeightSample(350, 215, 0),
          ..._breezeHeightSample(360, 225, 0),
          ..._breezeHeightSample(350, 215, 400),
          ..._breezeHeightSample(360, 225, 400),
        ],
      ).withSvgBoundaries(
        attackBoundary: attackBoundary,
        defenseBoundary: SvgVisionBoundary.parse(
          map: MapValue.breeze,
          source: defenseSvg,
        ),
      );
      final sourceGroup = _groupNearBounds(
        attackBoundary,
        const Rect.fromLTRB(1144.6, 443.6, 1200.8, 498.7),
      );
      final group = geometry.attackLayers.last.collisionGroups
          .singleWhere((candidate) => candidate.id == sourceGroup.id);

      expect(group.excludesObserverInLayer(0), isFalse);
      expect(group.excludesObserverInLayer(1), isTrue);
      expect(group.navigationLayerMask, 1 << 1);
    });

    test('mirrors attack geometry exactly for defense', () async {
      final source = await rootBundle.loadString(
        'assets/maps/ascent_vision.json',
      );
      final geometry = VisionGeometryMap.fromCompactJson(
        MapValue.ascent,
        jsonDecode(source) as Map<String, dynamic>,
      );
      final attack = geometry.attackLayers.first.segments.first;
      final defense = geometry.defenseLayers.first.segments.first;

      expect(attack.start.dx + defense.start.dx, closeTo(1000 * 16 / 9, 1e-6));
      expect(attack.start.dy + defense.start.dy, closeTo(1000, 1e-6));
      expect(attack.end.dx + defense.end.dx, closeTo(1000 * 16 / 9, 1e-6));
      expect(attack.end.dy + defense.end.dy, closeTo(1000, 1e-6));
    });

    test('loads geometry for every current competitive map', () async {
      for (final map in MapValue.values) {
        expect(Maps.hasVisionGeometry(map), isTrue, reason: map.name);
        final source = await rootBundle.loadString(
          'assets/maps/${Maps.mapNames[map]}_vision.json',
        );
        final geometry = VisionGeometryMap.fromCompactJson(
          map,
          jsonDecode(source) as Map<String, dynamic>,
        );
        expect(geometry.attackLayers, isNotEmpty, reason: map.name);
        expect(
          geometry.attackLayers.expand((layer) => layer.segments),
          isNotEmpty,
          reason: map.name,
        );
        final heightField = geometry.heightField;
        if (heightField != null) {
          final svg = await rootBundle.loadString(
            'assets/maps/${Maps.mapNames[map]}_map.svg',
          );
          final boundary = SvgVisionBoundary.parse(map: map, source: svg);
          final insideCount = heightField.samples
              .where((sample) => boundary.contains(sample.position))
              .length;
          expect(
            insideCount / heightField.samples.length,
            greaterThan(0.5),
            reason: '${map.name} navigation samples should align with its SVG',
          );
          expect(
            heightField.samples
                .map(
                  (sample) => geometry
                      .layerForPosition(
                        isAttack: true,
                        position: sample.position,
                      )
                      .elevation,
                )
                .toSet(),
            hasLength(greaterThan(1)),
            reason: '${map.name} should infer more than one height slice',
          );
        }
        for (final suffix in ['', '_defense']) {
          final svg = await rootBundle.loadString(
            'assets/maps/${Maps.mapNames[map]}_map$suffix.svg',
          );
          final boundary = SvgVisionBoundary.parse(map: map, source: svg);
          expect(boundary.segments, isNotEmpty, reason: '${map.name}$suffix');
          expect(boundary.contours, isNotEmpty, reason: '${map.name}$suffix');
        }

        final attackSvg = await rootBundle.loadString(
          'assets/maps/${Maps.mapNames[map]}_map.svg',
        );
        final defenseSvg = await rootBundle.loadString(
          'assets/maps/${Maps.mapNames[map]}_map_defense.svg',
        );
        final attackBoundary = SvgVisionBoundary.parse(
          map: map,
          source: attackSvg,
        );
        final defenseBoundary = SvgVisionBoundary.parse(
          map: map,
          source: defenseSvg,
        );
        final constrained = geometry.withSvgBoundaries(
          attackBoundary: attackBoundary,
          defenseBoundary: defenseBoundary,
        );
        _expectExactSvgRuntime(
          layers: constrained.attackLayers,
          boundary: attackBoundary,
          reason: '${map.name} attack',
        );
        _expectExactSvgRuntime(
          layers: constrained.defenseLayers,
          boundary: defenseBoundary,
          reason: '${map.name} defense',
        );

        if (map != MapValue.summit) {
          final alignment = Maps.visionGeometryAlignment[map];
          expect(alignment, isNotNull, reason: map.name);
          expect(
            alignment!.offset.distance,
            lessThanOrEqualTo(32),
            reason: '${map.name} calibration should stay a small correction',
          );
          expect(alignment.scaleX, inInclusiveRange(0.94, 1.06));
          expect(alignment.scaleY, inInclusiveRange(0.94, 1.06));
        }
      }
    });

    test('keeps every side of the split Icebox B box collision-active',
        () async {
      final source = await rootBundle.loadString(
        'assets/maps/icebox_vision.json',
      );
      final attackSvg = await rootBundle.loadString(
        'assets/maps/icebox_map.svg',
      );
      final boundary = SvgVisionBoundary.parse(
        map: MapValue.icebox,
        source: attackSvg,
      );
      final geometry = VisionGeometryMap.fromCompactJson(
        MapValue.icebox,
        jsonDecode(source) as Map<String, dynamic>,
      ).withSvgBoundaries(
        attackBoundary: boundary,
        defenseBoundary: boundary,
      );
      const expectedId = 'structuralObstacle_9a5d6569';
      final compound = boundary.collisionGroups.singleWhere(
        (group) => group.id == expectedId,
      );

      expect(
        compound.kind,
        VisionCollisionKind.structuralObstacle,
      );
      expect(compound.isClosed, isFalse);
      expect(compound.requiresEvidence, isFalse);
      expect(compound.paths, hasLength(3));
      expect(compound.segments, hasLength(9));
      final oneEndedCurve = boundary.collisionGroups.singleWhere(
        (group) =>
            group.kind == VisionCollisionKind.structuralChain &&
            group.bounds.left > 677 &&
            group.bounds.left < 679 &&
            group.bounds.right > 683 &&
            group.bounds.right < 685 &&
            group.bounds.top > 591 &&
            group.bounds.top < 593 &&
            group.bounds.bottom > 599 &&
            group.bounds.bottom < 601,
      );
      expect(oneEndedCurve.isClosed, isFalse);
      expect(
        boundary.collisionGroups.map((group) => group.id),
        isNot(
          contains(anyOf(
            'structuralChain_175beb4e',
            'structuralChain_1edf19ab',
            'structuralChain_227d3db2',
          )),
        ),
      );

      final layer = geometry.layerFor(isAttack: true, elevation: 320);
      expect(
        layer.collisionGroups.map((group) => group.id),
        contains(expectedId),
      );
      expect(
        layer.collisionGroups.map((group) => group.id),
        isNot(contains(oneEndedCurve.id)),
        reason: 'the one-ended curve must remain evidence-gated',
      );
      for (final ray in const <(Offset, double)>[
        (Offset(653.9081278, 599.6913319), 0),
        (Offset(670.8633075, 617.2262156), -math.pi / 2),
        (Offset(687.8184872, 599.6913319), math.pi),
      ]) {
        expect(
          _centerRayDistance(
            layer: layer,
            origin: ray.$1,
            facingAngle: ray.$2,
            range: 20,
          ),
          closeTo(10, 0.1),
          reason: 'Icebox B ray from ${ray.$1} crossed a box side',
        );
      }
    });

    test('keeps the Split B-site box collision-active', () async {
      final source = await rootBundle.loadString(
        'assets/maps/split_vision.json',
      );
      final attackSvg = await rootBundle.loadString(
        'assets/maps/split_map.svg',
      );
      final boundary = SvgVisionBoundary.parse(
        map: MapValue.split,
        source: attackSvg,
      );
      final geometry = VisionGeometryMap.fromCompactJson(
        MapValue.split,
        jsonDecode(source) as Map<String, dynamic>,
      ).withSvgBoundaries(
        attackBoundary: boundary,
        defenseBoundary: boundary,
      );
      const oldChainId = 'structuralChain_2bb9c03e';
      expect(
        boundary.collisionGroups.map((group) => group.id),
        isNot(contains(oldChainId)),
      );
      final box = boundary.collisionGroups.singleWhere(
        (group) =>
            group.kind == VisionCollisionKind.structuralObstacle &&
            _rectNear(
              group.bounds,
              const Rect.fromLTRB(446.9, 224.6, 464.9, 249.4),
              tolerance: 0.2,
            ),
      );

      expect(box.isClosed, isFalse);
      expect(box.paths, hasLength(3));
      expect(box.segments, hasLength(5));
      for (final layer in geometry.attackLayers) {
        expect(
            layer.collisionGroups.map((group) => group.id), contains(box.id));
        expect(_segmentKeys(layer.segments),
            containsAll(_segmentKeys(box.segments)));
      }
    });

    test('keeps the reported Split left box collision-active', () async {
      final source = await rootBundle.loadString(
        'assets/maps/split_vision.json',
      );
      final attackSvg = await rootBundle.loadString(
        'assets/maps/split_map.svg',
      );
      final boundary = SvgVisionBoundary.parse(
        map: MapValue.split,
        source: attackSvg,
      );
      final geometry = VisionGeometryMap.fromCompactJson(
        MapValue.split,
        jsonDecode(source) as Map<String, dynamic>,
      ).withSvgBoundaries(
        attackBoundary: boundary,
        defenseBoundary: boundary,
      );
      final box = boundary.collisionGroups.singleWhere(
        (group) =>
            group.kind == VisionCollisionKind.maskBoundary &&
            _rectNear(
              group.bounds,
              const Rect.fromLTRB(480.6, 357.3, 559.3, 394.8),
              tolerance: 0.2,
            ),
      );
      final origin = Offset(
        box.bounds.center.dx + 100,
        box.bounds.bottom + 300,
      );
      final facingAngle = math.atan2(
        box.bounds.center.dy - origin.dy,
        box.bounds.center.dx - origin.dx,
      );

      expect(box.isClosed, isTrue);
      for (final layer in geometry.attackLayers) {
        expect(
          layer.collisionGroups.map((group) => group.id),
          contains(box.id),
        );
        expect(
          _centerRayDistance(
            layer: layer,
            origin: origin,
            facingAngle: facingAngle,
            range: 500,
          ),
          closeTo(185.33, 0.1),
          reason: 'Split ray crossed the reported left-side box',
        );
      }
    });

    for (final fixture in const <({
      MapValue map,
      String asset,
      String oldChainId,
      String compoundId,
      Rect compoundBounds,
      Rect leakedChainBounds,
      int pathCount,
      int segmentCount,
    })>[
      (
        map: MapValue.fracture,
        asset: 'fracture',
        oldChainId: 'structuralChain_e2f0b69b',
        compoundId: 'structuralObstacle_9f91a55c',
        compoundBounds: Rect.fromLTRB(902.16, 911.39, 936.34, 934.96),
        leakedChainBounds: Rect.fromLTRB(916.31, 911.39, 925.73, 921.68),
        pathCount: 9,
        segmentCount: 18,
      ),
      (
        map: MapValue.summit,
        asset: 'summit',
        oldChainId: 'structuralChain_38757ff3',
        compoundId: 'structuralObstacle_37c33174',
        compoundBounds: Rect.fromLTRB(430.1, 38.1, 1346.8, 961.9),
        leakedChainBounds: Rect.fromLTRB(444.11, 319.49, 459.61, 326.20),
        pathCount: 16,
        segmentCount: 229,
      ),
    ]) {
      test(
          'promotes the ${fixture.asset} endpoint-to-interior cycle atomically',
          () async {
        final visionSource = await rootBundle.loadString(
          'assets/maps/${fixture.asset}_vision.json',
        );
        final svgSource = await rootBundle.loadString(
          'assets/maps/${fixture.asset}_map.svg',
        );
        final boundary = SvgVisionBoundary.parse(
          map: fixture.map,
          source: svgSource,
        );
        final compound = boundary.collisionGroups.singleWhere(
          (group) => group.id == fixture.compoundId,
        );
        final geometry = VisionGeometryMap.fromCompactJson(
          fixture.map,
          jsonDecode(visionSource) as Map<String, dynamic>,
        ).withSvgBoundaries(
          attackBoundary: boundary,
          defenseBoundary: boundary,
        );

        expect(
          boundary.collisionGroups.map((group) => group.id),
          isNot(contains(fixture.oldChainId)),
        );
        expect(compound.paths, hasLength(fixture.pathCount));
        expect(compound.segments, hasLength(fixture.segmentCount));
        expect(
          _rectNear(compound.bounds, fixture.compoundBounds, tolerance: 0.15),
          isTrue,
        );
        expect(
          compound.segments
              .where(
                (segment) => _segmentBoundsInside(
                  segment,
                  fixture.leakedChainBounds.inflate(0.15),
                ),
              )
              .length,
          greaterThanOrEqualTo(2),
          reason: 'the formerly rejected T-junction chain must be included',
        );
        for (final layer in geometry.attackLayers) {
          expect(
            layer.collisionGroups.map((group) => group.id),
            contains(compound.id),
          );
          expect(
            _segmentKeys(layer.segments),
            containsAll(_segmentKeys(compound.segments)),
          );
        }
      });
    }

    test('keeps the reported Breeze boxes as complete SVG obstacles', () async {
      final source = await rootBundle.loadString(
        'assets/maps/breeze_vision.json',
      );
      final attackSvg = await rootBundle.loadString(
        'assets/maps/breeze_map.svg',
      );
      final defenseSvg = await rootBundle.loadString(
        'assets/maps/breeze_map_defense.svg',
      );
      final attackBoundary = SvgVisionBoundary.parse(
        map: MapValue.breeze,
        source: attackSvg,
      );
      final geometry = VisionGeometryMap.fromCompactJson(
        MapValue.breeze,
        jsonDecode(source) as Map<String, dynamic>,
      ).withSvgBoundaries(
        attackBoundary: attackBoundary,
        defenseBoundary: SvgVisionBoundary.parse(
          map: MapValue.breeze,
          source: defenseSvg,
        ),
      );
      final leftBox = _groupNearBounds(
        attackBoundary,
        const Rect.fromLTRB(1144.6, 443.6, 1200.8, 498.7),
      );
      final rightBox = _groupNearBounds(
        attackBoundary,
        const Rect.fromLTRB(1242.9, 443.6, 1299.1, 498.7),
      );
      final diagonalBox = _groupNearBounds(
        attackBoundary,
        const Rect.fromLTRB(1127.3, 348.5, 1179.2, 400.4),
      );

      for (final group in [leftBox, rightBox, diagonalBox]) {
        expect(group.kind, VisionCollisionKind.structuralObstacle);
        expect(group.isClosed, isTrue);
        for (final layer in geometry.attackLayers) {
          expect(
            layer.collisionGroups.map((candidate) => candidate.id),
            contains(group.id),
            reason: '${group.id} disappeared at ${layer.elevation}',
          );
          expect(
            _segmentKeys(layer.segments),
            containsAll(_segmentKeys(group.segments)),
            reason: '${group.id} was only partially retained',
          );
        }
      }

      expect(
        _centerRayDistance(
          layer: VisionGeometryLayer(
            elevation: 0,
            segments: leftBox.segments,
          ),
          origin: const Offset(1110, 471),
          facingAngle: 0,
          range: 100,
        ),
        closeTo(34.6, 1),
      );
      expect(
        _centerRayDistance(
          layer: VisionGeometryLayer(
            elevation: 0,
            segments: rightBox.segments,
          ),
          origin: const Offset(1215, 471),
          facingAngle: 0,
          range: 100,
        ),
        closeTo(27.9, 1),
      );
      expect(
        _centerRayDistance(
          layer: VisionGeometryLayer(
            elevation: 0,
            segments: diagonalBox.segments,
          ),
          origin: const Offset(1100, 374.5),
          facingAngle: 0,
          range: 100,
        ),
        inInclusiveRange(20, 50),
      );
    });

    test('keeps the Breeze central stair strokes on supported layers',
        () async {
      final source = await rootBundle.loadString(
        'assets/maps/breeze_vision.json',
      );
      final attackSvg = await rootBundle.loadString(
        'assets/maps/breeze_map.svg',
      );
      final defenseSvg = await rootBundle.loadString(
        'assets/maps/breeze_map_defense.svg',
      );
      final attackBoundary = SvgVisionBoundary.parse(
        map: MapValue.breeze,
        source: attackSvg,
      );
      final geometry = VisionGeometryMap.fromCompactJson(
        MapValue.breeze,
        jsonDecode(source) as Map<String, dynamic>,
      ).withSvgBoundaries(
        attackBoundary: attackBoundary,
        defenseBoundary: SvgVisionBoundary.parse(
          map: MapValue.breeze,
          source: defenseSvg,
        ),
      );
      final topStroke = _groupNearBounds(
        attackBoundary,
        const Rect.fromLTRB(810.7, 507.4, 848.6, 507.4),
      );
      final bottomStroke = _groupNearBounds(
        attackBoundary,
        const Rect.fromLTRB(810.7, 521.4, 848.6, 521.4),
      );

      for (final group in [topStroke, bottomStroke]) {
        expect(group.kind, VisionCollisionKind.structuralChain);
        expect(group.isClosed, isFalse);
        for (final elevation in const [0.0, 700.0]) {
          final layer = geometry.layerFor(
            isAttack: true,
            elevation: elevation,
          );
          expect(
            layer.collisionGroups.map((candidate) => candidate.id),
            contains(group.id),
            reason: '${group.id} missing at $elevation',
          );
        }
      }

      expect(
        _centerRayDistance(
          layer: VisionGeometryLayer(
            elevation: 0,
            segments: [
              ...topStroke.segments,
              ...bottomStroke.segments,
            ],
          ),
          origin: const Offset(829.6, 550),
          facingAngle: -math.pi / 2,
          range: 100,
        ),
        closeTo(28.6, 1),
      );
    });
  });

  group('VisionPolygon', () {
    test('clips the center of a cone at the nearest wall', () {
      final layer = VisionGeometryLayer(
        elevation: 0,
        segments: [VisionSegment(const Offset(5, -10), const Offset(5, 10))],
      );

      final polygon = VisionPolygon.compute(
        layer: layer,
        origin: Offset.zero,
        facingAngle: 0,
        coneAngle: math.pi / 2,
        range: 10,
      );
      final centerPoint = polygon.skip(1).reduce(
            (best, point) => point.dy.abs() < best.dy.abs() ? point : best,
          );

      expect(centerPoint.dx, closeTo(5, 0.001));
      expect(centerPoint.dy, closeTo(0, 0.001));
    });

    test('uses the range arc when no wall blocks a ray', () {
      const origin = Offset(12, 18);
      const range = 30.0;
      final polygon = VisionPolygon.compute(
        layer: const VisionGeometryLayer(elevation: 0, segments: []),
        origin: origin,
        facingAngle: -math.pi / 2,
        coneAngle: math.pi / 3,
        range: range,
      );

      expect(polygon.length, greaterThan(20));
      for (final point in polygon.skip(1)) {
        expect((point - origin).distance, closeTo(range, 1e-8));
      }
    });

    test('excludes a passable closed group around its observer', () {
      final group = VisionCollisionGroup.geometry(
        points: const [
          Offset(5, -2),
          Offset(10, -2),
          Offset(10, 2),
          Offset(5, 2),
          Offset(5, -2),
        ],
        kind: VisionCollisionKind.structuralObstacle,
        isClosed: true,
      ).classify(
        layerMask: 1,
        evidenceLayerMask: 1,
        navigationLayerMask: 1,
        observerExclusionLayerMask: 1,
        coverageByLayer: const [1],
        confidence: VisionCollisionConfidence.matched,
        overrideApplied: false,
      );
      final layer = VisionGeometryLayer(
        elevation: 0,
        segments: group.segments,
        collisionGroups: [group],
        layerIndex: 0,
      );

      expect(
        _centerRayDistance(
          layer: layer,
          origin: const Offset(7.5, 0),
          facingAngle: 0,
          range: 20,
        ),
        closeTo(20, 1e-8),
      );
      expect(
        _centerRayDistance(
          layer: layer,
          origin: Offset.zero,
          facingAngle: 0,
          range: 20,
        ),
        closeTo(5, 0.001),
      );
    });

    test('retains a shared edge owned by a non-excluded group', () {
      final excluded = _classifiedGroup(
        points: const [
          Offset(0, 0),
          Offset(10, 0),
          Offset(10, 10),
          Offset(0, 10),
          Offset(0, 0),
        ],
        observerExclusionLayerMask: 1,
      );
      final retained = _classifiedGroup(
        points: const [
          Offset(10, 0),
          Offset(20, 0),
          Offset(20, 10),
          Offset(10, 10),
          Offset(10, 0),
        ],
        observerExclusionLayerMask: 0,
      );
      final segments = _deduplicateTestSegments([
        ...excluded.segments,
        ...retained.segments,
      ]);
      final layer = VisionGeometryLayer(
        elevation: 0,
        segments: segments,
        collisionGroups: [excluded, retained],
        layerIndex: 0,
        segmentIndex: VisionSegmentIndex(segments),
      );
      final available = _segmentKeys(
        layer.segmentsForObserver(const Offset(5, 5), 100),
      );
      final shared = excluded.segments.singleWhere(
        (segment) => segment.start.dx == 10 && segment.end.dx == 10,
      );
      final excludedOnly = excluded.segments.singleWhere(
        (segment) => segment.start.dx == 0 && segment.end.dx == 0,
      );

      expect(available, contains(visionSegmentKey(shared)));
      expect(available, isNot(contains(visionSegmentKey(excludedOnly))));
    });

    test('nested passability never permits an observer outside the footprint',
        () {
      final outer = VisionCollisionGroup.geometry(
        points: const [
          Offset(0, 0),
          Offset(10, 0),
          Offset(10, 10),
          Offset(0, 10),
          Offset(0, 0),
        ],
        kind: VisionCollisionKind.maskBoundary,
        isClosed: true,
        isOuterBoundary: true,
      );
      final nested = VisionCollisionGroup.geometry(
        points: const [
          Offset(20, 20),
          Offset(30, 20),
          Offset(30, 30),
          Offset(20, 30),
          Offset(20, 20),
        ],
        kind: VisionCollisionKind.maskBoundary,
        isClosed: true,
        nestingDepth: 1,
      ).classify(
        layerMask: 1,
        evidenceLayerMask: 0,
        navigationLayerMask: 1,
        observerExclusionLayerMask: 1,
        coverageByLayer: const [0],
        confidence: VisionCollisionConfidence.unmatchedDefault,
        overrideApplied: false,
      );
      final boundary = VisionBoundary(
        segments: [...outer.segments, ...nested.segments],
        maskSegments: outer.segments,
        contours: [outer.points],
        collisionGroups: [outer, nested],
        outerGroupId: outer.id,
        fillRule: VisionFillRule.evenOdd,
      );
      final layer = VisionGeometryLayer(
        elevation: 0,
        segments: [...outer.segments, ...nested.segments],
        boundary: boundary,
        collisionGroups: [outer, nested],
        observerGroups: [nested],
        layerIndex: 0,
      );
      const origin = Offset(25, 25);

      expect(nested.contains(origin), isTrue);
      expect(boundary.containsOuterFootprint(origin), isFalse);
      expect(layer.contains(origin), isFalse);
      expect(
        VisionPolygon.compute(
          layer: layer,
          origin: origin,
          facingAngle: 0,
          coneAngle: math.pi / 2,
          range: 20,
        ),
        [origin],
      );
    });

    test('leaves a real doorway gap open while its flanks block', () {
      final upper = VisionCollisionGroup.geometry(
        points: const [
          Offset(5, -10),
          Offset(10, -10),
          Offset(10, -1),
          Offset(5, -1),
          Offset(5, -10),
        ],
        kind: VisionCollisionKind.structuralObstacle,
        isClosed: true,
      );
      final lower = VisionCollisionGroup.geometry(
        points: const [
          Offset(5, 1),
          Offset(10, 1),
          Offset(10, 10),
          Offset(5, 10),
          Offset(5, 1),
        ],
        kind: VisionCollisionKind.structuralObstacle,
        isClosed: true,
      );
      final layer = VisionGeometryLayer(
        elevation: 0,
        segments: [...upper.segments, ...lower.segments],
      );

      expect(
        _centerRayDistance(
          layer: layer,
          origin: Offset.zero,
          facingAngle: 0,
          range: 20,
        ),
        closeTo(20, 1e-8),
      );
      expect(
        _centerRayDistance(
          layer: layer,
          origin: Offset.zero,
          facingAngle: math.atan2(2, 5),
          range: 20,
        ),
        closeTo(math.sqrt(29), 0.001),
      );
    });

    test('shared-vertex rays do not leak and are segment-order deterministic',
        () {
      final forward = VisionGeometryLayer(
        elevation: 0,
        segments: [
          VisionSegment(const Offset(5, -8), const Offset(5, 0)),
          VisionSegment(const Offset(5, 0), const Offset(5, 8)),
        ],
      );
      final reversed = VisionGeometryLayer(
        elevation: 0,
        segments: [
          VisionSegment(const Offset(5, 8), const Offset(5, 0)),
          VisionSegment(const Offset(5, 0), const Offset(5, -8)),
        ],
      );
      final first = VisionPolygon.compute(
        layer: forward,
        origin: Offset.zero,
        facingAngle: 0,
        coneAngle: math.pi / 2,
        range: 20,
      );
      final second = VisionPolygon.compute(
        layer: reversed,
        origin: Offset.zero,
        facingAngle: 0,
        coneAngle: math.pi / 2,
        range: 20,
      );

      final nearCorner = first.where(
        (point) => (point.dx - 5).abs() < 0.01 && point.dy.abs() < 0.01,
      );
      expect(nearCorner.length, greaterThanOrEqualTo(2));
      expect(first, hasLength(second.length));
      for (var index = 0; index < first.length; index += 1) {
        expect(second[index].dx, closeTo(first[index].dx, 1e-8));
        expect(second[index].dy, closeTo(first[index].dy, 1e-8));
      }
    });

    test('mirrored side positions and rotations produce symmetric clips', () {
      const worldWidth = 1000 * 16 / 9;
      const attackOrigin = Offset(50, 500);
      const defenseOrigin = Offset(worldWidth - 50, 500);
      final attackLayer = VisionGeometryLayer(
        elevation: 0,
        segments: [
          VisionSegment(const Offset(100, 450), const Offset(100, 550)),
        ],
      );
      final defenseLayer = VisionGeometryLayer(
        elevation: 0,
        segments: [
          VisionSegment(
            const Offset(worldWidth - 100, 550),
            const Offset(worldWidth - 100, 450),
          ),
        ],
      );

      final attack = VisionPolygon.compute(
        layer: attackLayer,
        origin: attackOrigin,
        facingAngle: 0,
        coneAngle: math.pi / 2,
        range: 100,
      );
      final defense = VisionPolygon.compute(
        layer: defenseLayer,
        origin: defenseOrigin,
        facingAngle: math.pi,
        coneAngle: math.pi / 2,
        range: 100,
      );

      expect(defense, hasLength(attack.length));
      for (var index = 0; index < attack.length; index += 1) {
        final mirroredDefense = Offset(
          worldWidth - defense[index].dx,
          1000 - defense[index].dy,
        );
        expect(mirroredDefense.dx, closeTo(attack[index].dx, 1e-8));
        expect(mirroredDefense.dy, closeTo(attack[index].dy, 1e-8));
      }
    });

    test('clips to a square extracted from the rendered SVG', () {
      const source = '''
<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <path fill="#271406" fill-rule="evenodd" d="M10 10H90V90H10Z"/>
</svg>
''';
      final boundary = SvgVisionBoundary.parse(
        map: MapValue.ascent,
        source: source,
      );
      final layer = VisionGeometryLayer(
        elevation: 0,
        segments: boundary.segments,
        boundary: boundary,
      );
      final bounds = boundary.segments.fold<Rect>(
        Rect.fromPoints(
          boundary.segments.first.start,
          boundary.segments.first.end,
        ),
        (rect, segment) => rect.expandToInclude(
          Rect.fromPoints(segment.start, segment.end),
        ),
      );
      final origin = bounds.center;
      final polygon = VisionPolygon.compute(
        layer: layer,
        origin: origin,
        facingAngle: 0,
        coneAngle: math.pi / 2,
        range: bounds.width,
      );
      final centerPoint = polygon.skip(1).reduce(
            (best, point) =>
                (point.dy - origin.dy).abs() < (best.dy - origin.dy).abs()
                    ? point
                    : best,
          );

      expect(boundary.contains(origin), isTrue);
      expect(centerPoint.dx, closeTo(bounds.right, 0.001));
      expect(centerPoint.dy, closeTo(origin.dy, 0.001));
    });

    test('does not paint a cone whose apex is outside the SVG floor mask', () {
      const source = '''
<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <path fill="#271406" d="M10 10H90V90H10Z"/>
</svg>
''';
      final boundary = SvgVisionBoundary.parse(
        map: MapValue.ascent,
        source: source,
      );
      final origin = boundary.segments
          .map((segment) => segment.start)
          .reduce((left, right) => left.dx < right.dx ? left : right)
          .translate(-10, 0);
      final polygon = VisionPolygon.compute(
        layer: VisionGeometryLayer(
          elevation: 0,
          segments: boundary.segments,
          boundary: boundary,
        ),
        origin: origin,
        facingAngle: 0,
        coneAngle: math.pi / 2,
        range: 100,
      );

      expect(boundary.contains(origin), isFalse);
      expect(polygon, [origin]);
    });
  });

  group('VisionSegmentIndex', () {
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
            if (_segmentBoundsOverlap(segments[candidate], query)) candidate,
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

Set<String> _segmentKeys(Iterable<VisionSegment> segments) => {
      for (final segment in segments) visionSegmentKey(segment),
    };

void _expectExactSvgRuntime({
  required List<VisionGeometryLayer> layers,
  required VisionBoundary boundary,
  required String reason,
}) {
  final allowedKeys = _segmentKeys(boundary.segments);
  for (final group in boundary.collisionGroups) {
    final exactPathKeys = <String>{
      for (final path in group.paths)
        for (var index = 1; index < path.length; index += 1)
          if ((path[index] - path[index - 1]).distanceSquared > 1e-9)
            visionSegmentKey(VisionSegment(path[index - 1], path[index])),
    };
    expect(
      _segmentKeys(group.segments),
      unorderedEquals(exactPathKeys),
      reason: '$reason ${group.id} synthesized a cross-path edge',
    );
  }
  for (final layer in layers) {
    final runtimeKeys = _segmentKeys(layer.segments);
    final groupedKeys = _segmentKeys(
      layer.collisionGroups.expand((group) => group.segments),
    );

    expect(layer.sourceSegments, isEmpty, reason: '$reason source geometry');
    expect(layer.riotSegments, isEmpty, reason: '$reason Riot leakage');
    expect(
      runtimeKeys,
      unorderedEquals(groupedKeys),
      reason: '$reason elevation ${layer.elevation} group union',
    );
    expect(
      runtimeKeys.every(allowedKeys.contains),
      isTrue,
      reason: '$reason elevation ${layer.elevation} must use exact SVG keys',
    );
    for (final group in layer.collisionGroups) {
      expect(
        group.activeInLayer(layer.layerIndex),
        isTrue,
        reason: '$reason ${group.id} has an inconsistent layer mask',
      );
      expect(
        runtimeKeys,
        containsAll(_segmentKeys(group.segments)),
        reason: '$reason ${group.id} is not atomically present',
      );
    }
  }
}

VisionCollisionGroup _groupNearBounds(
  VisionBoundary boundary,
  Rect expected, {
  double tolerance = 1,
}) {
  bool near(double actual, double target) =>
      (actual - target).abs() <= tolerance;
  return boundary.collisionGroups.singleWhere(
    (group) =>
        near(group.bounds.left, expected.left) &&
        near(group.bounds.top, expected.top) &&
        near(group.bounds.right, expected.right) &&
        near(group.bounds.bottom, expected.bottom),
  );
}

VisionGeometryMap _oneLayerGeometry(MapValue map) =>
    VisionGeometryMap.fromCompactJson(
      map,
      <String, dynamic>{
        'version': 2,
        'map': Maps.mapNames[map],
        'coordinateScale': 65536,
        'defaultElevation': 0,
        'observerHeight': 100,
        'heightSamples': <int>[],
        'layers': <Map<String, dynamic>>[
          <String, dynamic>{
            'elevation': 0,
            'vertices': <int>[],
            'edges': <int>[],
          },
        ],
      },
    );

VisionGeometryMap _twoLayerAscentGeometry() =>
    VisionGeometryMap.fromCompactJson(
      MapValue.ascent,
      <String, dynamic>{
        'version': 2,
        'map': 'ascent',
        'coordinateScale': 65536,
        'defaultElevation': 0,
        'observerHeight': 100,
        'heightSamples': <int>[],
        'layers': <Map<String, dynamic>>[
          <String, dynamic>{
            'elevation': 0,
            'vertices': <int>[],
            'edges': <int>[],
          },
          <String, dynamic>{
            'elevation': 500,
            'vertices': <int>[],
            'edges': <int>[],
          },
        ],
      },
    );

VisionGeometryMap _twoLayerBreezeGeometry({
  required List<int> heightSamples,
}) =>
    VisionGeometryMap.fromCompactJson(
      MapValue.breeze,
      <String, dynamic>{
        'version': 2,
        'map': 'breeze',
        'coordinateScale': 65536,
        'defaultElevation': 100,
        'observerHeight': 100,
        'heightSamples': heightSamples,
        'layers': <Map<String, dynamic>>[
          <String, dynamic>{
            'elevation': 100,
            'vertices': <int>[],
            'edges': <int>[],
          },
          <String, dynamic>{
            'elevation': 500,
            'vertices': <int>[],
            'edges': <int>[],
          },
        ],
      },
    );

List<int> _breezeHeightSample(double svgX, double svgY, int elevation) {
  const leftPadding = 14.878981;
  const topPadding = 14.878981;
  const paddedWidth = 447 + 14.878981 + 14.878981;
  const paddedHeight = 473 + 14.878981 + 23.248408;
  return <int>[
    (((svgX + leftPadding) / paddedWidth) * 65536).round(),
    (((svgY + topPadding) / paddedHeight) * 65536).round(),
    elevation,
  ];
}

VisionBoundary _overrideTestBoundary() {
  const source = '''
<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <path fill="#271406" d="M5 5H95V95H5Z"/>
  <path stroke="#B27C40" d="M30 30H40V40H30Z"/>
</svg>
''';
  return SvgVisionBoundary.parse(map: MapValue.ascent, source: source);
}

VisionCollisionGroup _classifiedGroup({
  required List<Offset> points,
  required int observerExclusionLayerMask,
}) =>
    VisionCollisionGroup.geometry(
      points: points,
      kind: VisionCollisionKind.structuralObstacle,
      isClosed: true,
    ).classify(
      layerMask: 1,
      evidenceLayerMask: 1,
      navigationLayerMask: observerExclusionLayerMask,
      observerExclusionLayerMask: observerExclusionLayerMask,
      coverageByLayer: const [1],
      confidence: VisionCollisionConfidence.matched,
      overrideApplied: false,
    );

List<VisionSegment> _deduplicateTestSegments(
  Iterable<VisionSegment> segments,
) {
  final keys = <String>{};
  return <VisionSegment>[
    for (final segment in segments)
      if (keys.add(visionSegmentKey(segment))) segment,
  ];
}

bool _segmentBoundsOverlap(VisionSegment segment, Rect bounds) =>
    segment.maxX >= bounds.left &&
    segment.minX <= bounds.right &&
    segment.maxY >= bounds.top &&
    segment.minY <= bounds.bottom;

bool _segmentBoundsInside(VisionSegment segment, Rect bounds) =>
    segment.minX >= bounds.left &&
    segment.maxX <= bounds.right &&
    segment.minY >= bounds.top &&
    segment.maxY <= bounds.bottom;

bool _rectNear(
  Rect actual,
  Rect expected, {
  required double tolerance,
}) =>
    (actual.left - expected.left).abs() <= tolerance &&
    (actual.top - expected.top).abs() <= tolerance &&
    (actual.right - expected.right).abs() <= tolerance &&
    (actual.bottom - expected.bottom).abs() <= tolerance;

double _centerRayDistance({
  required VisionGeometryLayer layer,
  required Offset origin,
  required double facingAngle,
  required double range,
}) {
  final polygon = VisionPolygon.compute(
    layer: layer,
    origin: origin,
    facingAngle: facingAngle,
    coneAngle: math.pi / 90,
    range: range,
  );
  double angularError(Offset point) {
    final delta = point - origin;
    var error = math.atan2(delta.dy, delta.dx) - facingAngle;
    while (error > math.pi) error -= math.pi * 2;
    while (error < -math.pi) error += math.pi * 2;
    return error.abs();
  }

  final centerPoint = polygon.skip(1).reduce(
        (best, point) =>
            angularError(point) < angularError(best) ? point : best,
      );
  expect(angularError(centerPoint), lessThan(1e-8));
  return (centerPoint - origin).distance;
}
