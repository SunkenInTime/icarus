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

  // A sealed perimeter wall blocks at every height, which the asset writes as
  // a band with no top and Dart holds as infinity. JSON has no infinity, so
  // copying a report that hit one used to throw mid-gesture and the user got
  // nothing on the clipboard.
  test('An unbounded band encodes as null instead of failing the copy', () {
    final model = SvgHeightVisibility.fromJson(jsonDecode(utf8.decode(
        gzip.decode(File('assets/maps/ascent_svg_height_attack.json.gz')
            .readAsBytesSync()))));
    final sealed = {
      for (final wall in model.walls)
        if (wall.bands.any((band) => !band.top.isFinite)) wall.id
    };
    expect(sealed, isNotEmpty, reason: 'Ascent has a sealed perimeter');

    final report = _reportLookingAt(model, sealed);
    expect(report, isNotNull, reason: 'no pose found looking at a sealed wall');

    final hits = (report!.json['hits'] as List).cast<Map<String, Object?>>();
    final bands = [
      for (final hit in hits)
        if (sealed.contains(hit['wallId']))
          ...(hit['bands'] as List).cast<List<Object?>>()
    ];
    expect(bands.any((band) => band.last == null), isTrue,
        reason: 'an unbounded top reads as null');
    expect(bands.every((band) => band.first != null), isTrue,
        reason: 'a floor-anchored base stays a number');
    // The copy itself, which is the call that used to throw.
    expect(() => jsonDecode(report.encode()), returnsNormally);
  });
}

/// The map data moves under this test, so the pose is found rather than fixed:
/// stand a short way off one of [wallIds]' corners and look back at it, from
/// whichever side of the wall is on the map.
SightlineReport? _reportLookingAt(
    SvgHeightVisibility model, Set<String> wallIds) {
  for (final wall in model.walls) {
    if (!wallIds.contains(wall.id)) continue;
    final corner = wall.rings.first.first;
    for (var quarter = 0; quarter < 4; quarter++) {
      final facing = quarter * math.pi / 2;
      final origin = corner - Offset(math.cos(facing), math.sin(facing)) * 25;
      if (!model.receiverContains(origin)) continue;
      final report = buildSightlineReport(
        map: 'ascent',
        isAttack: true,
        appVersion: '4.6.1',
        canonicalOrigin: const Offset(500, 500),
        svgOrigin: origin,
        facingRadians: facing,
        apertureRadians: math.pi / 8,
        rangeSvg: 60,
        savedElevationCm: null,
        model: model,
      );
      final hits = (report.json['hits'] as List).cast<Map<String, Object?>>();
      if (hits.any((hit) => wallIds.contains(hit['wallId']))) return report;
    }
  }
  return null;
}
