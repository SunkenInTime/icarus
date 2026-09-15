import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

void main() {
  test('native icon landmarks align with the unchanged SVG on every map',
      () async {
    final fixture = jsonDecode(
      File('test/fixtures/map_registration_landmarks.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final records = fixture['maps'] as List;
    expect(records.length, MapValue.values.length);
    final checked = <MapValue>{};
    for (final record in records) {
      final map = MapValue.values.byName(record['map'] as String);
      expect(checked.add(map), isTrue);
      final hash = await Sha256()
          .hash(File('assets/maps/${map.name}_map.svg').readAsBytesSync());
      expect(
        hash.bytes
            .map((value) => value.toRadixString(16).padLeft(2, '0'))
            .join(),
        record['svgSha256'],
        reason: '${map.name} artwork changed; recheck independent registration',
      );
      final box = Maps.mapViewBox[map]!;
      const worldHeight = 1000.0;
      const worldWidth = worldHeight * 16 / 9;
      const canvasWidth = worldHeight * CoordinateSystem.defaultMapAspectRatio;
      final scale = math.min(canvasWidth / box.width, worldHeight / box.height);
      final left = (worldWidth - box.width * scale) / 2;
      final top = (worldHeight - box.height * scale) / 2;
      for (final landmark in record['landmarks'] as List) {
        final uv = (landmark['nativeUv'] as List).cast<num>();
        final expected = (landmark['svg'] as List).cast<num>();
        final projected = VisionGeometryMap.projectUv(
          map,
          Offset(uv[0].toDouble(), uv[1].toDouble()),
        );
        final actualSvg =
            Offset((projected.dx - left) / scale, (projected.dy - top) / scale);
        final error =
            (actualSvg - Offset(expected[0].toDouble(), expected[1].toDouble()))
                .distance;
        expect(
            error, lessThanOrEqualTo(fixture['maximumResidualSvgUnits'] as num),
            reason: '${map.name} native $uv should align with SVG $expected');
      }
    }
  });
}
