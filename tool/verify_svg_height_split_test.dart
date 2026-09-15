// Actual Split data checks and warmed query timing. No Hive or asset mutation.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

const revision = 'E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision';
const fixturePath = 'E:/IcarusWorldAudit/2026-09-06/compact-prototype/'
    'native-walking-fixtures-v1/split/walking-144hz.json';

Map<String, num> distribution(List<int> values, {bool microseconds = true}) {
  final sorted = [...values]..sort();
  final suffix = microseconds ? 'Microseconds' : '';
  return {
    'samples': sorted.length,
    'median$suffix': sorted[(sorted.length - 1) ~/ 2],
    'p95$suffix': sorted[(sorted.length * .95).ceil() - 1],
    'maximum$suffix': sorted.last
  };
}

Map<String, Object?> hitJson(SvgVisibilityHit? hit) => hit == null
    ? {'clear': true}
    : {
        'wallId': hit.wallId,
        'pointSvg': [hit.point.dx, hit.point.dy],
        'distanceSvg': hit.distance,
        'unknownHeight': hit.unknownHeight
      };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('actual Split footprint, source height controls and warmed frozen pages',
      () async {
    final input = Platform.environment['ICARUS_SVG_HEIGHT_INPUT'] ??
        '$revision/split-svg-semantic-prototype-v2';
    final output = File(
        Platform.environment['ICARUS_SVG_HEIGHT_VERIFY_OUTPUT'] ??
            '$revision/split-svg-height-actual-verification-v1.json');
    if (output.existsSync())
      throw StateError('Preserve previous verification output.');
    final fixture = jsonDecode(await File(fixturePath).readAsString()) as Map;
    final frame = fixture['frames'][0] as Map;
    final sides = <Map<String, Object?>>[];
    for (final side in ['attack', 'defense']) {
      final file = File('$input/split-$side.json');
      final bytes = await file.readAsBytes();
      final parseWatch = Stopwatch()..start();
      final raw = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final model = SvgHeightVisibility.fromJson(raw);
      final parseMicroseconds = parseWatch.elapsedMicroseconds;
      final attack = side == 'attack';
      final support = model.supports.singleWhere((s) => s.id == 'box5803');
      final boxWall = model.walls.singleWhere((w) => w.id == 'box5803-wall-0');
      final opening =
          model.walls.singleWhere((w) => w.id == 'vent174-opening-0');
      final boxCenter = support.bounds.center;
      final groundOrigin = Offset(boxCenter.dx, attack ? 149 : 324);
      final groundDirection = attack ? -math.pi / 2 : math.pi / 2;
      final boxGround = model.castRay(
          origin: groundOrigin, directionRadians: groundDirection, range: 20);
      expect(boxGround?.wallId, boxWall.id);
      // Literal outer painted edge of the authored 1-unit box outline.
      expect(boxGround!.point.dy, closeTo(attack ? 143.433 : 329.567, 1e-9));
      expect(boxGround.unknownHeight, isFalse);
      final boxTop = model.castRay(
          origin: boxCenter,
          directionRadians: -groundDirection,
          range: 7,
          supportId: support.id);
      expect(boxTop, isNull);
      final boxTopCone = model.cone(
          origin: boxCenter,
          directionRadians: -groundDirection,
          range: 7,
          apertureRadians: 1.2,
          supportId: support.id);
      expect(boxTopCone.eyeHeightAboveFloorMeters,
          closeTo(support.heightAboveFloorMeters + 1.75, 1e-12));
      expect(boxTopCone.eyeHeightAboveFloorMeters,
          greaterThan(boxWall.bands.single.top));

      final openingOrigin =
          Offset(opening.bounds.center.dx, attack ? 202 : 271);
      final openingDirection = attack ? -math.pi / 2 : math.pi / 2;
      final throughOpening = model.castRay(
          origin: openingOrigin, directionRadians: openingDirection, range: 12);
      // Gameplay review rejects this asset-only gap as a useful sightline.
      expect(throughOpening?.wallId, opening.id);
      expect(throughOpening!.point.dy,
          closeTo(attack ? 196.596 : 276.404, 1e-9));
      final raisedOpening = model.castRay(
          origin: openingOrigin,
          directionRadians: openingDirection,
          range: 12,
          cameraHeightMeters: 4);
      expect(raisedOpening?.wallId, opening.id);
      expect(
          raisedOpening!.point.dy, closeTo(attack ? 196.596 : 276.404, 1e-9));

      final wallOrigin =
          attack ? const Offset(270, 90) : const Offset(196.1762, 383);
      final solid = model.castRay(
          origin: wallOrigin, directionRadians: openingDirection, range: 20);
      expect(solid, isNotNull);
      // These are the actual expanded gold footprint coordinates on each side,
      // including the small independently authored defense rounding.
      expect(solid!.point.dy, closeTo(attack ? 84.4221 : 388.578, 1e-9));

      // Actual path3 uses stroke-width="0.5" on this vertical detail.
      // Its painted edge is a quarter unit from the authored centerline.
      final thin = model.castRay(
          origin: attack ? const Offset(354, 150) : const Offset(112.1762, 323),
          directionRadians: attack ? 0 : math.pi,
          range: 8);
      expect(thin, isNotNull);
      expect(thin!.point.dx, closeTo(attack ? 357.505 : 108.671, 1e-9));

      final poses = List.generate(10, (i) {
        final p = frame['positionsSvg'][i] as List;
        final q = frame['poses'][i] as List;
        return (
          origin: Offset(
              attack
                  ? (p[0] as num).toDouble()
                  : 466.1762 - (p[0] as num).toDouble(),
              attack
                  ? (p[1] as num).toDouble()
                  : 473 - (p[1] as num).toDouble()),
          direction:
              math.atan2(-(q[4] as num).toDouble(), (q[3] as num).toDouble()) +
                  (attack ? 0 : math.pi),
          range: (q[5] as num).toDouble() * 3.9096202760784,
          aperture: (q[6] as num).toDouble()
        );
      });
      final queries = <int>[], pages = <int>[];
      final perPose = List.generate(10, (_) => <int>[]);
      final rayCounts = <int>[], edgeTests = <int>[];
      for (var page = -5; page < 30; page++) {
        final pageWatch = Stopwatch()..start();
        for (var i = 0; i < poses.length; i++) {
          final pose = poses[i];
          final watch = Stopwatch()..start();
          final cone = model.cone(
              origin: pose.origin,
              directionRadians: pose.direction,
              range: pose.range,
              apertureRadians: pose.aperture,
              cameraHeightMeters: 1.75);
          final elapsed = watch.elapsedMicroseconds;
          expect(cone.eyeHeightAboveFloorMeters, 1.75);
          if (page >= 0) {
            queries.add(elapsed);
            perPose[i].add(elapsed);
            rayCounts.add(cone.stats.rayCount);
            edgeTests.add(cone.stats.edgeTests);
          }
        }
        if (page >= 0) pages.add(pageWatch.elapsedMicroseconds);
      }
      final result = <String, Object?>{
        'side': side,
        'input': file.path,
        'inputBytes': bytes.length,
        'sourceSvg': raw['sourceSvg'],
        'parseMicroseconds': parseMicroseconds,
        'knownWallComponents':
            model.walls.where((w) => !w.unknownHeight).length,
        'unknownWallComponents':
            model.walls.where((w) => w.unknownHeight).length,
        'controls': {
          'boxGround': hitJson(boxGround),
          'boxTop': hitJson(boxTop),
          'boxTopEyeAboveFloorMeters': boxTopCone.eyeHeightAboveFloorMeters,
            'rejectedAssetOpeningBlocksStanding': hitJson(throughOpening),
          'raisedOpening': hitJson(raisedOpening),
          'solidGoldFootprint': hitJson(solid),
          'halfUnitStroke': hitJson(thin)
        },
        'queryCost': distribution(queries),
        'tenPosePageCost': distribution(pages),
        'perPoseQueryCost': [
          for (var i = 0; i < 10; i++)
            {
              'agentIndex': i,
              'originSvg': [poses[i].origin.dx, poses[i].origin.dy],
              ...distribution(perPose[i])
            }
        ],
        'rayCounts': distribution(rayCounts, microseconds: false),
        'edgeTestCounts': distribution(edgeTests, microseconds: false),
      };
      sides.add(result);
      // ignore: avoid_print
      print(
          '$side query ${distribution(queries)}; ten-pose page ${distribution(pages)}');
    }
    await output.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'passed': true,
      'fixture': fixturePath,
      'frame': 0,
      'sides': sides,
      'benchmark':
          'Flutter test mode, five warmup pages and thirty measured pages per side. '
              'Ten original frozen poses; standing1.75m above connected local floor. '
              'Query-only timings exclude SVG painting, icons and actual app frame scheduling. '
              'No production high-refresh-rate claim.',
      'limits':
            'Box5803 has source heights; vent174 is solid by gameplay review. '
              'Other height associations are explicitly unknown and opaque.',
      'productionMutation': false,
    }));
  });
}
