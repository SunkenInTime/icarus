import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

Map<String, dynamic> visibilityFixture() => {
      'version': 1,
      'map': 'split',
      'coordinateScale': 1000,
      'observerHeightCm': 175,
      'defaultFloorElevationCm': 300,
      'uvUnitsPerMeter': [.0078, .0078],
      'vertices': [600, 200, 600, 800, 700, 200, 700, 800, 800, 200, 800, 800],
      'edges': [0, 1, 2, 3, 4, 5],
      'layers': [
        {
          'elevationCm': 475,
          'globalOrigins': true,
          'edges': [0]
        },
        {
          'elevationCm': 525,
          'globalOrigins': false,
          'edges': [1]
        },
        {
          'elevationCm': 575,
          'globalOrigins': true,
          'edges': [2]
        },
      ],
      'menuElevationsCm': [475, 575],
    };

Map<String, dynamic> navigationFixture() => {
      'schemaVersion': 1,
      'map': 'split',
      'coordinateScale': 1000,
      'vertices': [200, 200, 300, 800, 200, 400, 800, 800, 400, 200, 800, 300],
      'polygons': [
        [0, 1, 2, 3]
      ],
      'triangles': [0, 0, 1, 2, 0, 0, 2, 3],
      'links': [],
      'components': [0],
      'walkable': [true],
    };

class _WorldBundle extends CachingAssetBundle {
  _WorldBundle({this.wrongMap = false, this.rangeCap});
  final bool wrongMap;
  final double? rangeCap;

  @override
  Future<ByteData> load(String key) async {
    final data = key.endsWith('_navigation.json.gz')
        ? navigationFixture()
        : visibilityFixture();
    if (wrongMap) data['map'] = 'sunset';
    if (rangeCap != null && key.endsWith('_visibility.json.gz')) {
      data['maxDistanceMeters'] = rangeCap;
    }
    final bytes = Uint8List.fromList(
        const GZipEncoder().encode(utf8.encode(jsonEncode(data))));
    return ByteData.sublistView(bytes);
  }
}

class _BinaryWorldBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    if (key.endsWith('_visibility.bin.gz')) {
      return ByteData.sublistView(
          await File('test/fixtures/world_visibility/delta-v1.bin.gz')
              .readAsBytes());
    }
    return _WorldBundle().load(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('binary gzip asset uses the same factory and physical projection',
      () async {
    final geometry = await loadWorldViewConeGeometry(MapValue.split,
        bundle: _BinaryWorldBundle(), binary: true);
    expect(geometry.elevations, [475]);
    expect(geometry.worldData!.elevations, [475, 477.125, 480]);
    final layer = geometry.layerFor(isAttack: true);
    expect(layer.metricLayer!.segments.length, 2);
    expect(layer.worldProjection, isNotNull);
    expect(layer.metricLayer!.maximumRange, 40);
  });

  test('gzip assets load off-thread and select standing slices from nav floors',
      () async {
    final geometry =
        await loadWorldViewConeGeometry(MapValue.split, bundle: _WorldBundle());
    Offset project(double u, double v) =>
        VisionGeometryMap.projectUv(MapValue.split, Offset(u, v));
    final origin = project(.5, .5);
    final reflected = Offset(1000 * (16 / 9) - origin.dx, 1000 - origin.dy);
    expect(geometry.inferredHeightAt(isAttack: true, position: origin),
        closeTo(525, 1e-7));
    expect(geometry.inferredHeightAt(isAttack: false, position: reflected),
        closeTo(525, 1e-7));
    final automatic =
        geometry.layerForPosition(isAttack: true, position: origin);
    expect(automatic.elevation, 525);
    expect(
        geometry
            .layerForPosition(
                isAttack: true, position: origin, elevationOverride: 475)
            .elevation,
        475);
    expect(geometry.elevations, [475, 575]);
    expect(geometry.layerFor(isAttack: true, elevation: 525).elevation, 475,
        reason: 'Manual elevation choices use globally valid layers.');
    expect(
        geometry
            .layerForPosition(
                isAttack: true, position: origin, elevationOverride: 525)
            .elevation,
        475);
    expect(geometry.attackLayers[1].contains(project(.25, .5)), isFalse,
        reason:
            'A local fine slice rejects origins belonging to another height.');
    expect(automatic.boundary, isNull,
        reason: 'A drawing outline must not become an eye-level blocker.');
    final direction = project(.7, .5) - origin;
    final polygon = VisionPolygon.compute(
      layer: automatic,
      origin: origin,
      facingAngle: math.atan2(direction.dy, direction.dx),
      coneAngle: .01,
      range: direction.distance * 2,
    );
    expect(polygon.any((p) => (p - project(.7, .5)).distance < 1e-7), isTrue);
    expect(automatic.contains(project(.1, .1)), isFalse);
  });

  test('optional source range limit caps physical queries without a fallback',
      () async {
    final geometry = await loadWorldViewConeGeometry(MapValue.split,
        bundle: _WorldBundle(rangeCap: 1));
    final origin =
        VisionGeometryMap.projectUv(MapValue.split, const Offset(.5, .5));
    final layer = geometry.layerForPosition(isAttack: true, position: origin);
    final projection = layer.worldProjection!;
    final physicalOrigin = projection.toMeters(origin);
    final polygon = VisionPolygon.compute(
        layer: layer,
        origin: origin,
        facingAngle: 0,
        coneAngle: math.pi / 2,
        range: 1000);
    expect(polygon.length, greaterThan(3));
    for (final point in polygon.skip(1)) {
      expect((projection.toMeters(point) - physicalOrigin).distance,
          closeTo(1, 1e-8));
    }
  });

  test('wrong-map assets fail without silently selecting legacy geometry',
      () async {
    await expectLater(
        loadWorldViewConeGeometry(MapValue.split,
            bundle: _WorldBundle(wrongMap: true)),
        throwsFormatException);
  });
}
