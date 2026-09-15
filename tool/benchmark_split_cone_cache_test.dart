import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_cone_cache.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  test('cached ten-observer updates preserve all actual Split polygons',
      () async {
    const root = 'E:/IcarusWorldAudit/2026-09-06';
    final fixture = jsonDecode(await File(
            '$root/compact-prototype/native-walking-fixtures-v1/split/walking-144hz.json')
        .readAsString());
    final frame = fixture['frames'][0];
    final reports = [];
    Map<String, num> distribution(List<int> samples) {
      final sorted = [...samples]..sort();
      return {
        'medianMicroseconds': sorted[sorted.length ~/ 2],
        'p95Microseconds': sorted[(sorted.length * .95).floor()],
        'maxMicroseconds': sorted.last
      };
    }

    for (final side in ['attack', 'defense']) {
      final candidate = Platform.environment['ICARUS_REGIONAL_CANDIDATE'];
      final asset = File(candidate == null
          ? 'assets/maps/split_svg_height_$side.json.gz'
          : '$candidate/candidate-$side.json.gz');
      final model = SvgHeightVisibility.fromJson(
          jsonDecode(utf8.decode(gzip.decode(await asset.readAsBytes()))));
      final cache = SvgHeightConeCache(model);
      final baselineTimes = <int>[], cachedTimes = <int>[];
      var comparisons = 0, calculated = 0;
      for (var tick = 0; tick < 140; tick++) {
        final active = (tick ~/ 12) % 10;
        final origins = <Offset>[],
            directions = <double>[],
            ranges = <double>[];
        for (var i = 0; i < 10; i++) {
          final p = frame['positionsSvg'][i];
          final q = frame['poses'][i];
          final origin = Offset(
              (p[0] as num).toDouble() +
                  (i == active ? sin(tick * .1) * .01 : 0),
              (p[1] as num).toDouble());
          origins.add(
              side == 'attack' ? origin : const Offset(466.1762, 473) - origin);
          directions.add(
              atan2(-(q[4] as num).toDouble(), (q[3] as num).toDouble()) +
                  (side == 'attack' ? 0 : pi));
          ranges.add((q[5] as num).toDouble() * 3.909620276078414);
        }
        final watch = Stopwatch()..start();
        final expected = [
          for (var i = 0; i < 10; i++)
            model.cone(
                origin: origins[i],
                directionRadians: directions[i],
                range: ranges[i],
                apertureRadians: (frame['poses'][i][6] as num).toDouble())
        ];
        final baseline = watch.elapsedMicroseconds;
        watch.reset();
        final actual = [
          for (var i = 0; i < 10; i++)
            cache.cone(
                observerId: i,
                origin: origins[i],
                directionRadians: directions[i],
                range: ranges[i],
                apertureRadians: (frame['poses'][i][6] as num).toDouble())
        ];
        final cached = watch.elapsedMicroseconds;
        watch.stop();
        final misses = actual.where((r) => !r.reused).length;
        if (tick > 0) expect(misses, lessThanOrEqualTo(2));
        for (var i = 0; i < 10; i++) {
          expect(actual[i].cone.polygon, expected[i].polygon);
          comparisons++;
        }
        if (tick >= 20) {
          baselineTimes.add(baseline);
          cachedTimes.add(cached);
          calculated += misses;
        }
      }
      reports.add({
        'side': side,
        'comparisons': comparisons,
        'baselineTenObserverUpdates': distribution(baselineTimes),
        'cachedTenObserverUpdates': distribution(cachedTimes),
        'calculatedConesIn120Updates': calculated,
        'scope':
            'Query-only local test; every observer takes a turn moving. No Flutter frame-rate claim.'
      });
    }
    final output = Platform.environment['ICARUS_SPLIT_CACHE_OUTPUT'] ??
        'work/split-cone-cache-verification.json';
    await File(output).parent.create(recursive: true);
    expect(File(output).existsSync(), isFalse);
    await File(output)
        .writeAsString(const JsonEncoder.withIndent('  ').convert(reports));
    // ignore: avoid_print
    print(jsonEncode(reports));
  });
}
