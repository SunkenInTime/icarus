import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/sightline_report.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  test('Pearl attack sightline report describes the pose it was built from',
      () {
    final model = SvgHeightVisibility.fromJson(jsonDecode(utf8.decode(
        gzip.decode(File('assets/maps/pearl_svg_height_attack.json.gz')
            .readAsBytesSync()))));
    const origin = Offset(255, 278);
    final report = buildSightlineReport(
      map: 'pearl',
      isAttack: true,
      appVersion: '4.6.1',
      canonicalOrigin: const Offset(500, 500),
      svgOrigin: origin,
      // Straight down the map, in SVG coordinates.
      facingRadians: math.pi / 2,
      apertureRadians: math.pi / 2,
      rangeSvg: 70,
      savedElevationCm: null,
      model: model,
    );

    final json = report.json;
    expect(json['version'], 1);
    expect(json['map'], 'pearl');
    expect(json['side'], 'attack');
    expect(json['runtime'], 'svg-height');
    expect(json['svgOrigin'], [255.0, 278.0]);

    final standing = json['standing'] as Map<String, Object?>;
    expect(standing['groundMeters'] as double, closeTo(8, .05));
    expect(standing['automatic'], isTrue);
    expect(standing['eyeMeters'] as double,
        closeTo(8 + model.defaultCameraHeightMeters, .05));

    final hits = (json['hits'] as List).cast<Map<String, Object?>>();
    expect(hits, isNotEmpty);
    expect(hits.length, sightlineReportRayCount + 1);
    // Angles are absolute, so the centre ray reads as the facing itself.
    expect(hits.map((hit) => hit['angleRadians'] as double),
        contains(closeTo(math.pi / 2, .001)));
    final wallIds = {for (final wall in model.walls) wall.id};
    final blocked =
        hits.where((hit) => hit['wallId'] != null).toList(growable: false);
    expect(blocked, isNotEmpty);
    for (final hit in blocked) {
      expect(wallIds, contains(hit['wallId']));
      expect(hit['distanceSvg'] as double, lessThanOrEqualTo(70));
      expect(hit['bands'], isA<List<Object?>>());
    }

    final decoded = jsonDecode(report.encode()) as Map<String, dynamic>;
    expect(decoded['map'], 'pearl');
    expect((decoded['hits'] as List).length, hits.length);
    expect(decoded['note'], '');
  });
}
