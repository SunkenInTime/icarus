import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/view_cone/svg_vision_boundary.dart';
import 'package:icarus/view_cone/authored_vision_boundary.dart';
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

  test('provider selects the authored Split boundary at runtime', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final geometry =
        await container.read(viewConeGeometryProvider(MapValue.split).future);

    expect(geometry, isNotNull);
    expect(geometry!.attackLayers.first.collisionGroups, hasLength(27));
    expect(
      geometry.attackLayers.first.collisionGroups.any(
        (group) =>
            group.kind == VisionCollisionKind.maskBoundary &&
            !group.isOuterBoundary &&
            (group.bounds.center - const Offset(520, 376)).distance < 10,
      ),
      isTrue,
    );
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

      for (final layer in [
        ...geometry.attackLayers,
        ...geometry.defenseLayers
      ]) {
        expect(
          layer.collisionGroups,
          hasLength(expectedGroupCount),
          reason: '${map.name} elevation ${layer.elevation}',
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
