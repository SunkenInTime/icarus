// Offline source comparison; never opens the user's saved strategies.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/page_transition/navigation_geometry.dart';
import 'package:icarus/view_cone/height_assets.dart';
import 'package:icarus/view_cone/height_native.dart';

double _cross(Offset a, Offset b) => a.dx * b.dy - a.dy * b.dx;

/// First intersection of a ray with the native union of opaque shadow triangles.
/// This uses half-plane clipping, independently of the shader and raster pixels.
double _firstShadow(Float32List mesh, Offset direction, double range) {
  var first = range;
  for (var i = 0; i < mesh.length; i += 6) {
    final p = [
      for (var j = 0; j < 3; j++) Offset(mesh[i + 2 * j], mesh[i + 2 * j + 1])
    ];
    final area = _cross(p[1] - p[0], p[2] - p[0]);
    if (area.abs() < 1e-12) continue;
    final sign = area.sign;
    var low = 0.0, high = first;
    var possible = true;
    for (var j = 0; j < 3; j++) {
      final edge = p[(j + 1) % 3] - p[j];
      final coefficient = _cross(edge, direction) * sign;
      final constant = _cross(edge, -p[j]) * sign;
      if (coefficient.abs() < 1e-12) {
        if (constant < 0) possible = false;
      } else if (coefficient > 0) {
        low = math.max(low, -constant / coefficient);
      } else {
        high = math.min(high, -constant / coefficient);
      }
    }
    if (possible && low <= high && high >= 0) first = math.min(first, low);
  }
  return first;
}

Future<void> _checkRay(HeightNativeWorker worker, Map<String, dynamic> ray,
    String label, int stamp) async {
  final origin = (ray['origin'] as List).cast<num>();
  final target = (ray['target'] as List).cast<num>();
  expect(origin[2], target[2], reason: '$label must be horizontal');
  final vector = Offset(
      (target[0] - origin[0]).toDouble(), (target[1] - origin[1]).toDouble());
  final distance = vector.distance;
  final direction = vector / distance;
  final query = Float64List.fromList([
    ...origin.map((v) => v.toDouble()),
    direction.dx,
    direction.dy,
    distance + 1,
    103 * math.pi / 180,
  ]);
  final mesh = (await worker.compute(stamp, query)).cone(0);
  final actual = _firstShadow(mesh, direction, distance + 1);
  if (ray['blocked'] == true) {
    final expected = ((ray['hit'] as Map)['distanceMeters'] as num).toDouble();
    expect(actual, closeTo(expected, .005), reason: label);
  } else {
    expect(actual, greaterThanOrEqualTo(distance - .005), reason: label);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = jsonDecode(
      File('test/fixtures/tactical_semantic_reference.json')
          .readAsStringSync()) as Map<String, dynamic>;

  test(
      'ray intersection checker handles both winding orders and a missed triangle',
      () {
    for (final p in [
      [2.0, -1, 2, 1, 4, 0],
      [2.0, -1, 4, 0, 2, 1]
    ]) {
      expect(
          _firstShadow(
              Float32List.fromList(p.map((v) => v.toDouble()).toList()),
              const Offset(1, 0),
              10),
          2);
      expect(
          _firstShadow(
              Float32List.fromList(p.map((v) => v.toDouble()).toList()),
              const Offset(-1, 0),
              10),
          10);
    }
  });

  test(
      'live Split landmarks remain qualified and standing clears crate below the opening',
      () {
    final rows =
        (fixture['lowCoverCases'] as List).cast<Map<String, dynamic>>();
    for (final row in rows) {
      expect(row['liveExactPoseVerified'], isFalse);
      expect(row['liveLandmarkMatched'], isTrue);
    }
    final standing = rows.singleWhere((r) => r['id'] == 'split-b-crate-1.75');
    final sensitivity =
        rows.singleWhere((r) => r['id'] == 'split-b-crate-1.95');
    final eye = standing['modelRay']['origin'][2] as num;
    expect(eye, greaterThan(standing['crateTopMeters'] as num));
    expect(eye, lessThan(standing['openingLowerEdgeMeters'] as num));
    expect(standing['clearTargetBeforeWall']['blocked'], isFalse);
    expect(standing['modelRay']['blocked'], isTrue);
    expect(
        sensitivity['modelRay']['hit']['distanceMeters'] as num,
        greaterThan(
            (standing['modelRay']['hit']['distanceMeters'] as num) + .2));
    expect(sensitivity['category'], 'height-sensitivity-only');
  });

  test(
      'actual native shadows preserve low cover and separate stacked observer floors',
      () async {
    final library = File(Platform.environment['ICARUS_SEMANTIC_LIBRARY'] ??
            'E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision/baseline-icarus_height.dll')
        .absolute
        .path;
    final lowCover =
        (fixture['lowCoverCases'] as List).cast<Map<String, dynamic>>();
    final corners =
        (fixture['opaqueCornerCases'] as List).cast<Map<String, dynamic>>();
    final overlaps =
        (fixture['overlapCases'] as List).cast<Map<String, dynamic>>();
    var rays = 0;
    for (final name in {'split', ...overlaps.map((r) => r['map'] as String)}) {
      final map = MapValue.values.byName(name);
      final assets = await loadHeightAssets(map,
          cacheRoot: Directory('build/semantic-height-cache'));
      expect(assets.entry.packSha256, fixture['mapAssets'][name]['packSha256']);
      expect(assets.entry.navigationSha256,
          fixture['mapAssets'][name]['navigationSha256']);
      final packedNav = await loadVerifiedHeightNavigation(map);
      final data = jsonDecode(utf8.decode(gzip.decode(packedNav)))
          as Map<String, dynamic>;
      final t = assets.entry.uiTransform;
      Offset native(Offset uv) => Offset(
          (uv.dy - t['YScalarToAdd']!) / (100 * t['YMultiplier']!),
          -(uv.dx - t['XScalarToAdd']!) / (100 * t['XMultiplier']!));
      final nav = NavigationGeometry.fromJson(data, projectUv: native);
      final worker = await HeightNativeWorker.open(library, assets.folder, 4);
      try {
        for (final row
            in [...lowCover, ...corners].where((r) => r['map'] == name)) {
          await _checkRay(worker, row['modelRay'] as Map<String, dynamic>,
              row['id'] as String, rays++);
          if (row['clearTargetBeforeWall'] != null) {
            await _checkRay(
                worker,
                row['clearTargetBeforeWall'] as Map<String, dynamic>,
                '${row['id']} crate clearance',
                rays++);
          }
        }
        for (final row in overlaps.where((r) => r['map'] == name)) {
          expect(assets.entry.packSha256, row['sourcePackSha256']);
          expect(assets.entry.navigationSha256, row['sourceNavigationSha256']);
          final xy = (row['originXY'] as List).cast<num>();
          final floors =
              nav.floorHeightsAt(Offset(xy[0].toDouble(), xy[1].toDouble()));
          for (final height in (row['floorMeters'] as List).cast<num>()) {
            expect(floors.any((value) => (value - height * 100).abs() < .05),
                isTrue,
                reason: '${row['id']} must retain selected floor $height');
          }
          for (final pair
              in (row['horizontalRays'] as List).cast<Map<String, dynamic>>()) {
            for (final floor in ['lower', 'upper']) {
              await _checkRay(
                  worker,
                  pair[floor] as Map<String, dynamic>,
                  '${row['id']} $floor direction ${pair['directionIndex']}',
                  rays++);
            }
          }
        }
      } finally {
        await worker.close();
      }
    }
    expect(rays, 166);
    stdout.writeln(
        'SEMANTIC_FIXTURES $rays source/native ray comparisons, 10 overlapping-floor cases. No exact live-camera certification.');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
