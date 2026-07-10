import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
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
  });
}
