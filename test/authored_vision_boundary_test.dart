import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/view_cone/svg_vision_boundary.dart';
import 'package:icarus/view_cone/authored_vision_boundary.dart';
import 'package:icarus/view_cone/vision_boundary_edit_document.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const expectedCounts = <MapValue, (int, int)>{
    MapValue.bind: (15, 6),
    MapValue.haven: (9, 17),
    MapValue.split: (9, 17),
    MapValue.ascent: (9, 18),
    MapValue.icebox: (9, 0),
    MapValue.breeze: (17, 20),
    MapValue.fracture: (8, 16),
    MapValue.pearl: (13, 15),
    MapValue.lotus: (15, 13),
    MapValue.sunset: (10, 24),
    MapValue.abyss: (17, 0),
    MapValue.corrode: (9, 0),
    MapValue.summit: (13, 31),
  };

  // These are the authored walls that overlap Riot navigation samples. The
  // overlap is useful evidence for selecting an elevation, but must never
  // turn the whole enclosing wall into a passable floor. Icebox is the most
  // sensitive case: the old behavior could remove seven of its nine walls.
  const navigationOverlapCounts = <MapValue, int>{
    MapValue.bind: 6,
    MapValue.haven: 2,
    MapValue.split: 4,
    MapValue.ascent: 1,
    MapValue.icebox: 7,
    MapValue.breeze: 2,
    MapValue.fracture: 3,
    MapValue.pearl: 4,
    MapValue.lotus: 0,
    MapValue.sunset: 3,
    MapValue.abyss: 2,
    MapValue.corrode: 3,
    MapValue.summit: 0,
  };

  test('loads the complete authored collision manifest for every map',
      () async {
    final manifest = jsonDecode(
      await rootBundle.loadString(
        'assets/maps/vision_collision_reference.json',
      ),
    ) as Map<String, dynamic>;

    for (final map in MapValue.values) {
      final svg = SvgVisionBoundary.parse(
        map: map,
        source: await rootBundle.loadString(
          'assets/maps/${map.name}_map.svg',
        ),
      );
      final boundary = AuthoredVisionBoundary.parse(
        map: map,
        document: manifest,
        attackTargetBounds: svg.outerGroup.bounds,
      );
      final defense = AuthoredVisionBoundary.parse(
        map: map,
        document: manifest,
        attackTargetBounds: svg.outerGroup.bounds,
        isDefense: true,
      );
      final counts = expectedCounts[map]!;

      expect(boundary.outerGroup.bounds, _closeRect(svg.outerGroup.bounds));
      expect(
        boundary.collisionGroups
            .where((group) => group.kind == VisionCollisionKind.maskBoundary),
        hasLength(1 + counts.$1),
        reason: '${map.name} base contours',
      );
      expect(
        boundary.collisionGroups.where(
          (group) => group.kind == VisionCollisionKind.structuralObstacle,
        ),
        hasLength(counts.$2),
        reason: '${map.name} height boxes',
      );
      expect(
        boundary.collisionGroups.every(
          (group) => group.isClosed && group.segments.length >= 2,
        ),
        isTrue,
        reason: '${map.name} polygons must remain atomic closed groups',
      );

      final attackBounds = boundary.outerGroup.bounds;
      final defenseBounds = defense.outerGroup.bounds;
      expect(defenseBounds.left,
          closeTo(1000 * (16 / 9) - attackBounds.right, 0.001));
      expect(defenseBounds.top, closeTo(1000 - attackBounds.bottom, 0.001));
      expect(defenseBounds.right,
          closeTo(1000 * (16 / 9) - attackBounds.left, 0.001));
      expect(defenseBounds.bottom, closeTo(1000 - attackBounds.top, 0.001));
    }
  });

  test('includes the reported Split left box as one complete contour',
      () async {
    final manifest = jsonDecode(
      await rootBundle.loadString(
        'assets/maps/vision_collision_reference.json',
      ),
    ) as Map<String, dynamic>;
    final svg = SvgVisionBoundary.parse(
      map: MapValue.split,
      source: await rootBundle.loadString('assets/maps/split_map.svg'),
    );
    final boundary = AuthoredVisionBoundary.parse(
      map: MapValue.split,
      document: manifest,
      attackTargetBounds: svg.outerGroup.bounds,
    );

    final box = boundary.collisionGroups.singleWhere(
      (group) =>
          group.kind == VisionCollisionKind.maskBoundary &&
          !group.isOuterBoundary &&
          (group.bounds.center - const Offset(520, 376)).distance < 10,
    );

    expect(box.segments, hasLength(4));
    expect(box.bounds.left, closeTo(481.1, 1));
    expect(box.bounds.top, closeTo(358.2, 1));
    expect(box.bounds.right, closeTo(558.6, 1));
    expect(box.bounds.bottom, closeTo(393.8, 1));
  });

  test('provider selects the exact rendered Split boundary at runtime',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final svg = SvgVisionBoundary.parse(
      map: MapValue.split,
      source: await rootBundle.loadString('assets/maps/split_map.svg'),
    );

    final geometry =
        await container.read(viewConeGeometryProvider(MapValue.split).future);

    expect(geometry, isNotNull);
    final runtimeBoundary = geometry!.attackLayers.first.boundary!;
    expect(
      runtimeBoundary.segments.map(visionSegmentKey).toSet(),
      svg.segments.map(visionSegmentKey).toSet(),
    );
  });

  test('provider enables exact rendered collision geometry for Summit',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final svg = SvgVisionBoundary.parse(
      map: MapValue.summit,
      source: await rootBundle.loadString('assets/maps/summit_map.svg'),
    );

    final geometry =
        await container.read(viewConeGeometryProvider(MapValue.summit).future);

    expect(geometry, isNotNull);
    expect(geometry!.attackLayers, isNotEmpty);
    expect(
      geometry.attackLayers.first.boundary!.segments
          .map(visionSegmentKey)
          .toSet(),
      svg.segments.map(visionSegmentKey).toSet(),
    );
  });

  test('runtime walls exactly match rendered SVG strokes on every map',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    for (final map in MapValue.values) {
      final attackSvg = SvgVisionBoundary.parse(
        map: map,
        source: await rootBundle.loadString(
          'assets/maps/${map.name}_map.svg',
        ),
      );
      final defenseSvg = SvgVisionBoundary.parse(
        map: map,
        source: await rootBundle.loadString(
          'assets/maps/${map.name}_map_defense.svg',
        ),
        isAttack: false,
      );
      final exactDraft = VisionBoundaryMapDraft.fromBoundary(
        map: map,
        boundary: attackSvg,
      );
      final editorBoundary = AuthoredVisionBoundary.parse(
        map: map,
        document: <String, dynamic>{
          'version': 1,
          'maps': <String, dynamic>{map.name: exactDraft.toJson()},
        },
        attackTargetBounds: attackSvg.outerGroup.bounds,
      );
      expect(
        editorBoundary.segments.map(visionSegmentKey).toSet(),
        attackSvg.segments.map(visionSegmentKey).toSet(),
        reason: '${map.name} editor round-trip fidelity',
      );
      final editorSegments = {
        for (final segment in editorBoundary.segments)
          visionSegmentKey(segment): segment,
      };
      for (final exactSegment in attackSvg.segments) {
        expect(
          editorSegments[visionSegmentKey(exactSegment)]!.collisionRadius,
          closeTo(exactSegment.collisionRadius, 0.00001),
          reason: '${map.name} editor stroke-width fidelity',
        );
      }
      expect(
        editorBoundary.collisionGroups.where(
          (group) => group.kind == VisionCollisionKind.structuralChain,
        ),
        everyElement(
          predicate<VisionCollisionGroup>(
            (group) => group.isAuthoritative,
            'a manually editable wall chain that bypasses evidence admission',
          ),
        ),
        reason: '${map.name} edited wall authority',
      );
      final geometry =
          await container.read(viewConeGeometryProvider(map).future);
      expect(geometry, isNotNull, reason: map.name);

      for (final side in <(String, VisionBoundary, List<VisionGeometryLayer>)>[
        ('attack', attackSvg, geometry!.attackLayers),
        ('defense', defenseSvg, geometry.defenseLayers),
      ]) {
        final exactKeys = side.$2.segments.map(visionSegmentKey).toSet();
        final exactCollisionKeys = side.$2.collisionGroups
            .expand((group) => group.collisionSegments)
            .map(visionSegmentKey)
            .toSet();
        expect(
          side.$2.collisionGroups.where(
            (group) => group.kind == VisionCollisionKind.maskBoundary,
          ),
          everyElement(
            predicate<VisionCollisionGroup>(
              (group) => !group.inferObserverPassability,
              'an exact SVG mask that cannot disappear around the observer',
            ),
          ),
          reason: '${map.name} ${side.$1} mask semantics',
        );
        expect(
          side.$3.first.boundary!.segments.map(visionSegmentKey).toSet(),
          exactKeys,
          reason: '${map.name} ${side.$1} boundary source',
        );
        for (final layer in side.$3) {
          final activeKeys = layer.segments.map(visionSegmentKey).toSet();
          expect(
            activeKeys,
            everyElement(isIn(exactCollisionKeys)),
            reason:
                '${map.name} ${side.$1} elevation ${layer.elevation} fidelity',
          );
          expect(
            layer.observerGroups.where(
              (group) => group.kind == VisionCollisionKind.maskBoundary,
            ),
            isEmpty,
            reason:
                '${map.name} ${side.$1} masks must remain walls on every elevation',
          );
        }
      }
    }
  });

  test('Ascent B wall clips on the rendered stroke instead of beside it',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final geometry =
        await container.read(viewConeGeometryProvider(MapValue.ascent).future);
    final wall = geometry!.attackLayers.first.debugCollisionGroups.singleWhere(
      (group) =>
          group.kind == VisionCollisionKind.structuralChain &&
          (group.bounds.left - 636.8).abs() < 0.1 &&
          (group.bounds.top - 234.2).abs() < 0.1,
    );
    final visibleVertical = wall.segments.singleWhere(
      (segment) =>
          (segment.start.dx - segment.end.dx).abs() < 0.001 &&
          (segment.start.dx - 636.8).abs() < 0.1,
    );

    expect(
      visibleVertical.collisionRadius,
      closeTo(1000 / 474 / 2, 0.00001),
      reason: 'LOS must stop at the near edge of Ascent’s 1-unit wall stroke',
    );

    for (final layer in geometry.attackLayers) {
      expect(
        layer.collisionGroups.map((group) => group.id),
        contains(wall.id),
        reason: 'Ascent elevation ${layer.elevation}',
      );
      expect(
        layer.segments.map(visionSegmentKey),
        contains(visionSegmentKey(visibleVertical)),
        reason: 'Ascent elevation ${layer.elevation}',
      );
    }
  });

  test('saved boundary edits remain valid authored geometry', () async {
    final reference = jsonDecode(
      await rootBundle.loadString(visionBoundaryReferenceAsset),
    ) as Map<String, dynamic>;
    final edits = jsonDecode(
      await rootBundle.loadString(visionBoundaryEditsAsset),
    ) as Map<String, dynamic>;
    final merged = mergeVisionBoundaryDocuments(
      reference: reference,
      edits: edits,
    );

    for (final map in MapValue.values) {
      final svg = SvgVisionBoundary.parse(
        map: map,
        source: await rootBundle.loadString(
          'assets/maps/${map.name}_map.svg',
        ),
      );
      final boundary = AuthoredVisionBoundary.parse(
        map: map,
        document: merged,
        attackTargetBounds: svg.outerGroup.bounds,
      );
      expect(boundary.collisionGroups, isNotEmpty, reason: map.name);
    }
  });

  test('keeps every authored group active when merged with Riot layers',
      () async {
    final manifest = jsonDecode(
      await rootBundle.loadString(
        'assets/maps/vision_collision_reference.json',
      ),
    ) as Map<String, dynamic>;

    for (final map in MapValue.values) {
      final svg = SvgVisionBoundary.parse(
        map: map,
        source: await rootBundle.loadString(
          'assets/maps/${map.name}_map.svg',
        ),
      );
      final attack = AuthoredVisionBoundary.parse(
        map: map,
        document: manifest,
        attackTargetBounds: svg.outerGroup.bounds,
      );
      final defense = AuthoredVisionBoundary.parse(
        map: map,
        document: manifest,
        attackTargetBounds: svg.outerGroup.bounds,
        isDefense: true,
      );
      final geometrySource = jsonDecode(
        await rootBundle.loadString('assets/maps/${map.name}_vision.json'),
      ) as Map<String, dynamic>;
      final geometry = VisionGeometryMap.fromCompactJson(map, geometrySource)
          .withSvgBoundaries(
        attackBoundary: attack,
        defenseBoundary: defense,
      );
      final counts = expectedCounts[map]!;
      final expectedGroupCount = 1 + counts.$1 + counts.$2;

      for (final side in <(String, List<VisionGeometryLayer>)>[
        ('attack', geometry.attackLayers),
        ('defense', geometry.defenseLayers),
      ]) {
        final authoredInteriors = side.$2.first.debugCollisionGroups.where(
          (group) =>
              group.kind == VisionCollisionKind.maskBoundary &&
              !group.isOuterBoundary,
        );
        expect(
          authoredInteriors.where(
            (group) => group.navigationLayerMask != 0,
          ),
          hasLength(navigationOverlapCounts[map]!),
          reason: '${map.name} ${side.$1} navigation overlap audit',
        );
        expect(
          authoredInteriors,
          everyElement(
            predicate<VisionCollisionGroup>(
              (group) =>
                  !group.inferObserverPassability &&
                  group.observerExclusionLayerMask == 0,
              'an authored wall that cannot become observer-passable',
            ),
          ),
          reason: '${map.name} ${side.$1} authored wall semantics',
        );
      }

      for (final layer in [
        ...geometry.attackLayers,
        ...geometry.defenseLayers
      ]) {
        expect(
          layer.collisionGroups,
          hasLength(expectedGroupCount),
          reason: '${map.name} elevation ${layer.elevation}',
        );
        expect(
          layer.collisionGroups.where(
            (group) =>
                group.kind == VisionCollisionKind.maskBoundary &&
                !group.isOuterBoundary,
          ),
          everyElement(
            predicate<VisionCollisionGroup>(
              (group) => !group.excludesObserverInLayer(layer.layerIndex),
              'an authored interior that always remains a wall',
            ),
          ),
          reason:
              '${map.name} interiors must not be inferred as passable floors',
        );
      }
      if (counts.$2 > 0) {
        final layer = geometry.attackLayers.first;
        final heightBox = layer.collisionGroups.firstWhere(
          (group) => group.removesOwnEdgesWhenInside,
        );
        final origin = heightBox.bounds.center;
        expect(heightBox.contains(origin), isTrue, reason: map.name);
        final visibleKeys = layer
            .segmentsForObserver(origin, 2000)
            .map(visionSegmentKey)
            .toSet();
        expect(
          heightBox.segments.map(visionSegmentKey),
          everyElement(isNot(isIn(visibleKeys))),
          reason: '${map.name} height box must remove its own edges inside',
        );
      }
    }
  });
}

Matcher _closeRect(Rect expected) => predicate<Rect>(
      (actual) =>
          (actual.left - expected.left).abs() < 0.001 &&
          (actual.top - expected.top).abs() < 0.001 &&
          (actual.right - expected.right).abs() < 0.001 &&
          (actual.bottom - expected.bottom).abs() < 0.001,
      'a rectangle within 0.001 of $expected',
    );
