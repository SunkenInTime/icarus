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

    test('transfers matched Riot blockers onto exact SVG geometry', () async {
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
        geometry.attackLayers.map((layer) => layer.riotSegments.length).toSet(),
        hasLength(greaterThan(1)),
      );
      expect(
        geometry.attackLayers.expand((layer) => layer.matchedSourceSegments),
        isNotEmpty,
      );
      expect(
        geometry.attackLayers.expand((layer) => layer.matchedBoundarySegments),
        isNotEmpty,
      );
      for (final layer in geometry.attackLayers) {
        expect(layer.riotSegments, isNotEmpty);
        expect(layer.boundarySegments, isNotEmpty);
        expect(
          layer.segments,
          containsAll(layer.matchedBoundarySegments),
        );
        expect(
          layer.segments.length,
          layer.riotSegments.length + layer.boundarySegments.length,
        );
        expect(layer.boundary, isNotNull);
      }
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
        final constrained = geometry.withSvgBoundaries(
          attackBoundary: SvgVisionBoundary.parse(
            map: map,
            source: attackSvg,
          ),
          defenseBoundary: SvgVisionBoundary.parse(
            map: map,
            source: defenseSvg,
          ),
        );
        final sourceSegmentCount = geometry.attackLayers
            .map((layer) => layer.riotSegments.length)
            .reduce((left, right) => left + right);
        final keptSegmentCount = constrained.attackLayers
            .map((layer) => layer.riotSegments.length)
            .reduce((left, right) => left + right);
        final matchedSegmentCount = constrained.attackLayers
            .map((layer) => layer.matchedSourceSegments.length)
            .reduce((left, right) => left + right);
        final rejectedSegmentCount = constrained.attackLayers
            .map((layer) => layer.rejectedSegments.length)
            .reduce((left, right) => left + right);
        if (map == MapValue.summit) {
          expect(keptSegmentCount, 0);
          expect(rejectedSegmentCount, 0);
        } else {
          expect(
            keptSegmentCount + matchedSegmentCount + rejectedSegmentCount,
            sourceSegmentCount,
            reason: '${map.name} should classify every Riot segment',
          );
          expect(
            (keptSegmentCount + matchedSegmentCount) / sourceSegmentCount,
            greaterThan(0.8),
            reason: '${map.name} filtering should remain conservative',
          );
          expect(
            rejectedSegmentCount / sourceSegmentCount,
            lessThan(0.2),
            reason: '${map.name} should reject only clear map-space outliers',
          );
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

    test('casts vertex-adjacent event rays to avoid corner light leaks', () {
      final layer = VisionGeometryLayer(
        elevation: 0,
        segments: [VisionSegment(const Offset(5, 0), const Offset(5, 8))],
      );
      final polygon = VisionPolygon.compute(
        layer: layer,
        origin: Offset.zero,
        facingAngle: 0,
        coneAngle: math.pi / 2,
        range: 20,
      );

      final nearCorner = polygon.where(
        (point) => (point.dx - 5).abs() < 0.01 && point.dy.abs() < 0.01,
      );
      expect(nearCorner.length, greaterThanOrEqualTo(2));
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
