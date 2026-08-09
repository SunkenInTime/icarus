import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/svg_vision_boundary.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

import 'vision_geometry_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
            segmentKeys(layer.segments), segmentKeys(layer.boundarySegments));
        expect(
          segmentKeys(layer.segments),
          segmentKeys(
            layer.collisionGroups.expand(
              (group) => group.collisionSegments,
            ),
          ),
        );
        for (final group in layer.collisionGroups) {
          expect(
            segmentKeys(layer.segments),
            containsAll(segmentKeys(group.segments)),
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
          segmentKeys(layer.segments),
          containsAll(segmentKeys(closedDetail.segments)),
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
      final rejected = oneLayerGeometry(MapValue.ascent).withSvgBoundaries(
        attackBoundary: boundary,
        defenseBoundary: boundary,
      );
      final admitted = oneLayerGeometry(MapValue.ascent).withSvgBoundaries(
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
        segmentKeys(admitted.attackLayers.single.segments),
        containsAll(segmentKeys(compound.segments)),
      );
    });

    test('rejects outer, unknown-contour, and unknown-elevation overrides', () {
      final boundary = overrideTestBoundary();
      final geometry = twoLayerAscentGeometry();
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
      final geometry = oneLayerGeometry(MapValue.summit).withSvgBoundaries(
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
      final geometry = twoLayerBreezeGeometry(
        heightSamples: [
          ...breezeHeightSample(350, 215, 400),
          ...breezeHeightSample(360, 225, 400),
        ],
      ).withSvgBoundaries(
        attackBoundary: attackBoundary,
        defenseBoundary: defenseBoundary,
      );
      final attackSourceGroup = groupNearBounds(
        attackBoundary,
        const Rect.fromLTRB(1144.6, 443.6, 1200.8, 498.7),
      );
      final defenseSourceGroup = groupNearBounds(
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
      final geometry = twoLayerBreezeGeometry(
        heightSamples: [
          ...breezeHeightSample(350, 215, 0),
          ...breezeHeightSample(360, 225, 0),
          ...breezeHeightSample(350, 215, 400),
          ...breezeHeightSample(360, 225, 400),
        ],
      ).withSvgBoundaries(
        attackBoundary: attackBoundary,
        defenseBoundary: SvgVisionBoundary.parse(
          map: MapValue.breeze,
          source: defenseSvg,
        ),
      );
      final sourceGroup = groupNearBounds(
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
        expectExactSvgRuntime(
          layers: constrained.attackLayers,
          boundary: attackBoundary,
          reason: '${map.name} attack',
        );
        expectExactSvgRuntime(
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
          centerRayDistance(
            layer: layer,
            origin: ray.$1,
            facingAngle: ray.$2,
            range: 20,
          ),
          closeTo(10 - compound.segments.first.collisionRadius, 0.1),
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
            rectNear(
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
        expect(segmentKeys(layer.segments),
            containsAll(segmentKeys(box.segments)));
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
            rectNear(
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
        final hit = centerRayPoint(
          layer: layer,
          origin: origin,
          facingAngle: facingAngle,
          range: 500,
        );
        expect(
          (hit - origin).distance,
          lessThan(185.33),
          reason: 'Split ray crossed the reported left-side box',
        );
        expectOnVisibleStroke(hit, layer.segments);
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
          rectNear(compound.bounds, fixture.compoundBounds, tolerance: 0.15),
          isTrue,
        );
        expect(
          compound.segments
              .where(
                (segment) => segmentBoundsInside(
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
            segmentKeys(layer.segments),
            containsAll(segmentKeys(compound.segments)),
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
      final leftBox = groupNearBounds(
        attackBoundary,
        const Rect.fromLTRB(1144.6, 443.6, 1200.8, 498.7),
      );
      final rightBox = groupNearBounds(
        attackBoundary,
        const Rect.fromLTRB(1242.9, 443.6, 1299.1, 498.7),
      );
      final diagonalBox = groupNearBounds(
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
            segmentKeys(layer.segments),
            containsAll(segmentKeys(group.segments)),
            reason: '${group.id} was only partially retained',
          );
        }
      }

      expect(
        centerRayDistance(
          layer: VisionGeometryLayer(
            elevation: 0,
            segments: leftBox.segments,
          ),
          origin: const Offset(1110, 471),
          facingAngle: 0,
          range: 100,
        ),
        closeTo(34.6 - leftBox.segments.first.collisionRadius, 1),
      );
      expect(
        centerRayDistance(
          layer: VisionGeometryLayer(
            elevation: 0,
            segments: rightBox.segments,
          ),
          origin: const Offset(1215, 471),
          facingAngle: 0,
          range: 100,
        ),
        closeTo(27.9 - rightBox.segments.first.collisionRadius, 1),
      );
      expect(
        centerRayDistance(
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
      final topStroke = groupNearBounds(
        attackBoundary,
        const Rect.fromLTRB(810.7, 507.4, 848.6, 507.4),
      );
      final bottomStroke = groupNearBounds(
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
        centerRayDistance(
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
        closeTo(28.6 - topStroke.segments.first.collisionRadius, 1),
      );
    });
  });
}
