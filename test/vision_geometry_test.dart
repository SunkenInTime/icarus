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

    test('keeps elevation metadata when SVG boundaries replace wall data',
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
        geometry.attackLayers.map((layer) => layer.segments),
        everyElement(same(geometry.attackLayers.first.segments)),
      );
      expect(geometry.attackLayers.first.boundary, isNotNull);
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
        for (final suffix in ['', '_defense']) {
          final svg = await rootBundle.loadString(
            'assets/maps/${Maps.mapNames[map]}_map$suffix.svg',
          );
          final boundary = SvgVisionBoundary.parse(map: map, source: svg);
          expect(boundary.segments, isNotEmpty, reason: '${map.name}$suffix');
          expect(boundary.contours, isNotEmpty, reason: '${map.name}$suffix');
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
