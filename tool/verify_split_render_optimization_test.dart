import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

const root = 'E:/IcarusWorldAudit/2026-09-06';
const revision = '$root/tactical-visibility-revision';
const modelPath = '$revision/split-svg-semantic-prototype-v17';

double distance(Offset p, Offset a, Offset b) {
  final d = b - a;
  if (d.distanceSquared == 0) return (p - a).distance;
  final t = (((p - a).dx * d.dx + (p - a).dy * d.dy) / d.distanceSquared)
      .clamp(0.0, 1.0);
  return (p - (a + d * t)).distance;
}

double boundaryDistance(Offset p, List<Offset> ring) {
  var best = double.infinity;
  for (var i = 0; i < ring.length; i++) {
    best = math.min(best, distance(p, ring[i], ring[(i + 1) % ring.length]));
  }
  return best;
}

void main() {
  test(
      'visibility optimization preserves complete actual Split cone boundaries',
      () async {
    final recording = Platform.environment['ICARUS_RECORD_REFERENCE'] == '1';
    final path = File('$revision/split-cone-reference-v17.json');
    final fixture = jsonDecode(await File(
            '$root/compact-prototype/native-walking-fixtures-v1/split/walking-144hz.json')
        .readAsString());
    final reviews = jsonDecode(
            await File('$modelPath/review-poses.json').readAsString())['cases']
        as List;
    final models = {
      for (final side in ['attack', 'defense'])
        side: SvgHeightVisibility.fromJson(jsonDecode(
            await File('$modelPath/split-$side.json').readAsString()))
    };
    final nativePath = Platform.environment['ICARUS_SVG_NATIVE_LIBRARY'];
    if (nativePath != null) {
      for (final model in models.values) {
        expect(model.enableNativeAcceleration(libraryPath: nativePath), true);
        addTearDown(model.closeNativeAcceleration);
      }
    }
    final poses = <Map<String, dynamic>>[
      for (final p in reviews) Map<String, dynamic>.from(p)
    ];
    for (var frame = 0; frame < 420; frame += 21) {
      final f = fixture['frames'][frame];
      for (final side in ['attack', 'defense'])
        for (var i = 0; i < 10; i++) {
          final p = f['positionsSvg'][i];
          final q = f['poses'][i];
          poses.add({
            'id': 'walking-$frame-$i-$side',
            'side': side,
            'originSvg': side == 'attack' ? p : [466.1762 - p[0], 473 - p[1]],
            'directionRadians': math.atan2(
                    -(q[4] as num).toDouble(), (q[3] as num).toDouble()) +
                (side == 'attack' ? 0 : math.pi),
            'rangeSvg': q[5] * 3.9096202760784,
            'apertureRadians': q[6]
          });
        }
    }
    final reference =
        recording ? null : jsonDecode(await path.readAsString()) as List;
    final byId =
        reference == null ? null : {for (final r in reference) r['id']: r};
    if (byId != null) poses.removeWhere((p) => !byId.containsKey(p['id']));
    final output = [];
    var maxDistance = 0.0;
    var oldRays = 0, newRays = 0;
    final times = <int>[];
    for (var index = 0; index < poses.length; index++) {
      final p = poses[index];
      final model = models[p['side']]!;
      final result = model.cone(
          origin: Offset((p['originSvg'][0] as num).toDouble(),
              (p['originSvg'][1] as num).toDouble()),
          directionRadians: (p['directionRadians'] as num).toDouble(),
          range: (p['rangeSvg'] as num).toDouble(),
          apertureRadians: (p['apertureRadians'] as num).toDouble(),
          supportId: p['supportId'] as String?);
      times.add(result.stats.elapsedMicroseconds);
      if (recording) {
        output.add({
          'id': p['id'],
          'points': [
            for (final v in result.polygon) [v.dx, v.dy]
          ],
          'rays': result.stats.rayCount,
          'time': result.stats.elapsedMicroseconds
        });
        continue;
      }
      final r = byId![p['id']];
      expect(p['id'], r['id']);
      final expected = [
        for (final q in r['points'])
          Offset((q[0] as num).toDouble(), (q[1] as num).toDouble())
      ];
      for (final q in expected) {
        maxDistance =
            math.max(maxDistance, boundaryDistance(q, result.polygon));
      }
      for (final q in result.polygon) {
        maxDistance = math.max(maxDistance, boundaryDistance(q, expected));
      }
      if (maxDistance >= 0.00001) {
        await File('$revision/split-optimization-mismatch.json')
            .writeAsString(jsonEncode({
          'pose': p,
          'expected': r['points'],
          'actual': [
            for (final q in result.polygon) [q.dx, q.dy]
          ]
        }));
      }
      expect(maxDistance, lessThan(0.00001), reason: p['id']);
      oldRays += (r['rays'] as int);
      newRays += result.stats.rayCount;
    }
    if (recording) {
      expect(path.existsSync(), false);
      await path.writeAsString(jsonEncode(output));
    }
    times.sort();
    final report = {
      'cones': poses.length,
      'native': nativePath != null,
      'maximumBoundaryDeviationSvg': maxDistance,
      'oldRays': oldRays,
      'newRays': newRays,
      'medianMicros': times[times.length ~/ 2],
      'p95Micros': times[(times.length * .95).floor()]
    };
    if (!recording)
      await File(
              '$revision/split-cone-${nativePath == null ? 'optimization' : 'native'}-verification-v1.json')
          .writeAsString(jsonEncode(report));
    // ignore: avoid_print
    print(jsonEncode(report));
  }, timeout: const Timeout(Duration(minutes: 4)));
}
