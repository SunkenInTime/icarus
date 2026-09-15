// Paired measurement against the preserved pre-cleanup implementation.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'file:///E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision/svg-edge-cleanup-benchmark-v1/svg_height_visibility_after_cleanup.dart';
import 'file:///E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision/svg-edge-cleanup-benchmark-v1/svg_height_visibility_before_cleanup.dart'
    as before;

const folder = 'E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision/'
    'svg-edge-cleanup-benchmark-v1';
const fixturePath = 'E:/IcarusWorldAudit/2026-09-06/compact-prototype/'
    'native-walking-fixtures-v1/split/walking-144hz.json';

Map<String, int> summary(List<int> values) {
  final sorted = [...values]..sort();
  return {
    'samples': sorted.length,
    'median': sorted[(sorted.length - 1) ~/ 2],
    'p95': sorted[(sorted.length * .95).ceil() - 1]
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('unchanged cast contacts and paired warmed actual Split pages',
      () async {
    final output = File('$folder/report.json');
    if (output.existsSync()) throw StateError('Preserve previous benchmark.');
    final frame = (jsonDecode(await File(fixturePath).readAsString())
        as Map)['frames'][0] as Map;
    final records = <Map>[];
    for (final side in ['attack', 'defense']) {
      final data =
          jsonDecode(await File('$folder/split-$side.json').readAsString())
              as Map<String, dynamic>;
      final old = before.SvgHeightVisibility.fromJson(data);
      final current = SvgHeightVisibility.fromJson(data);
      final models = <dynamic>[old, current];
      expect(current.walls.length, old.walls.length);
      for (var i = 0; i < current.walls.length; i++) {
        expect(current.walls[i].rings, old.walls[i].rings);
      }
      final poses = List.generate(10, (i) {
        final p = frame['positionsSvg'][i] as List,
            q = frame['poses'][i] as List;
        return (
          origin: Offset(
              side == 'attack'
                  ? (p[0] as num).toDouble()
                  : 466.1762 - (p[0] as num).toDouble(),
              side == 'attack'
                  ? (p[1] as num).toDouble()
                  : 473 - (p[1] as num).toDouble()),
          direction:
              math.atan2(-(q[4] as num).toDouble(), (q[3] as num).toDouble()) +
                  (side == 'attack' ? 0 : math.pi),
          range: (q[5] as num).toDouble() * 3.9096202760784,
          aperture: (q[6] as num).toDouble()
        );
      });
      var maximumPointDifference = 0.0, exactPoints = 0, rayPairs = 0;
      final ownershipTies = <Map>[];
      for (final pose in poses) {
        for (var i = 0; i <= 16; i++) {
          final angle = pose.direction + pose.aperture * (i / 16 - .5);
          final a = old.castRay(
              origin: pose.origin, directionRadians: angle, range: pose.range);
          final b = current.castRay(
              origin: pose.origin, directionRadians: angle, range: pose.range);
          rayPairs++;
          expect(a == null, b == null);
          if (a == null || b == null) continue;
          expect(a.unknownHeight, b.unknownHeight);
          final difference = (a.point - b.point).distance;
          if (a.wallId != b.wallId) {
            ownershipTies.add({
              'origin': [pose.origin.dx, pose.origin.dy],
              'angle': angle,
              'beforeWall': a.wallId,
              'afterWall': b.wallId,
              'beforePoint': [a.point.dx, a.point.dy],
              'afterPoint': [b.point.dx, b.point.dy],
              'differenceSvg': difference
            });
          }
          maximumPointDifference = math.max(maximumPointDifference, difference);
          if (a.point == b.point) exactPoints++;
          // Geometry was not approximated. Different arithmetic on a longer
          // identical straight edge may change the last binary64 bits.
          expect(difference, lessThan(1e-10));
        }
      }
      final queryTimes = [<int>[], <int>[]], pageTimes = [<int>[], <int>[]];
      final rays = [<int>[], <int>[]], edges = [<int>[], <int>[]];
      for (var page = -5; page < 30; page++) {
        for (final version in page.isEven ? [0, 1] : [1, 0]) {
          final watchPage = Stopwatch()..start();
          for (final pose in poses) {
            final watch = Stopwatch()..start();
            final dynamic cone = models[version].cone(
                origin: pose.origin,
                directionRadians: pose.direction,
                range: pose.range,
                apertureRadians: pose.aperture,
                cameraHeightMeters: 1.75);
            final elapsed = watch.elapsedMicroseconds;
            if (page >= 0) {
              queryTimes[version].add(elapsed);
              rays[version].add(cone.stats.rayCount as int);
              edges[version].add(cone.stats.edgeTests as int);
            }
          }
          if (page >= 0) pageTimes[version].add(watchPage.elapsedMicroseconds);
        }
      }
      var oldEdges = 0;
      for (final wall in old.walls) {
        for (final ring in wall.rings) {
          for (var i = 0; i < ring.length; i++) {
            if (ring[i] != ring[(i + 1) % ring.length]) oldEdges++;
          }
        }
      }
      final record = {
        'side': side,
        'literalSourceRingsUnchanged': true,
        'beforeRuntimeEdges': oldEdges,
        'afterRuntimeEdges': current.runtimeEdgeCount,
        'representativeRayPairs': rayPairs,
        'bitwiseEqualHitPoints': exactPoints,
        'maximumHitPointDifferenceSvg': maximumPointDifference,
        'coincidentOwnershipTies': ownershipTies,
        'beforeQueryMicroseconds': summary(queryTimes[0]),
        'afterQueryMicroseconds': summary(queryTimes[1]),
        'beforeTenPosePageMicroseconds': summary(pageTimes[0]),
        'afterTenPosePageMicroseconds': summary(pageTimes[1]),
        'beforeRayCounts': summary(rays[0]),
        'afterRayCounts': summary(rays[1]),
        'beforeEdgeTests': summary(edges[0]),
        'afterEdgeTests': summary(edges[1])
      };
      records.add(record);
      // ignore: avoid_print
      print(jsonEncode(record));
    }
    await output.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'passed': true,
      'records': records,
      'method':
          'Same frozen modelv2 data and ten original poses; implementations alternate order each page. '
              'Five warmup and thirty measured pages per side. Flutter test mode, query-only.',
      'geometryRule':
          'Remove exact consecutive/closing duplicates and strictly forward horizontal/vertical intermediates. '
              'No tolerance; preserve original rings, curves and diagonals.',
      'productionMutation': false,
    }));
  });
}
