import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  test('record focused roof selection with isolated removal controls', () {
    final input = jsonDecode(File(
            Platform.environment['ICARUS_ROOF_PROBE_INPUT'] ??
                'work/systematic-map-review/focused/roof-probe-input.json')
        .readAsStringSync()) as List;
    final result = <Map<String, dynamic>>[];
    for (final map in input) {
      final name = map['map'];
      final excluded = {for (final c in map['candidates']) c['supportId']};
      final excludedDomains = {
        for (final c in map['candidates']) '$name-measured-${c['domainId']}'
      };
      final a = map['alignment']['nativeToAttackSvg'] as List;
      final d = map['alignment']['nativeToDefenseSvg'] as List;
      Offset reflect(List xy, String side) {
        final x = (xy[0] as num).toDouble(), y = (xy[1] as num).toDouble();
        if (side == 'attack') return Offset(x, y);
        final det = a[0][0] * a[1][1] - a[0][1] * a[1][0];
        final nx = ((x - a[0][2]) * a[1][1] - (y - a[1][2]) * a[0][1]) / det;
        final ny = (a[0][0] * (y - a[1][2]) - a[1][0] * (x - a[0][2])) / det;
        return Offset(d[0][0] * nx + d[0][1] * ny + d[0][2],
            d[1][0] * nx + d[1][1] * ny + d[1][2]);
      }

      for (final side in ['attack', 'defense']) {
        final data = jsonDecode(utf8.decode(gzip.decode(
            File('assets/maps/${name}_svg_height_$side.json.gz')
                .readAsBytesSync()))) as Map<String, dynamic>;
        final before = SvgHeightVisibility.fromJson(data);
        final after = SvgHeightVisibility.fromJson({
          ...data,
          'supports': (data['supports'] as List)
              .where((s) =>
                  !excluded.contains(s['id']) &&
                  !excludedDomains.contains(s['id']))
              .toList()
        });
        for (final c in map['candidates']) {
          for (final p in c['retainedLowerFloorExamples']) {
            final point = reflect(p['svg'], side);
            Map state(SvgHeightVisibility model) {
              final support = model.automaticSupportAt(point);
              return {
                'supportId': support?.id,
                'floor': support?.surfaceElevationAt(point) ??
                    model.ground?.heightAt(point),
                'available': [
                  for (final s in model.supportsAt(point))
                    {
                      'id': s.id,
                      'height': s.surfaceElevationAt(point),
                      'automatic': s.automaticStandingAllowed
                    }
                ]
              };
            }

            result.add({
              'map': name,
              'side': side,
              'domainId': c['domainId'],
              'point': [point.dx, point.dy],
              'before': state(before),
              'isolatedRemoval': state(after)
            });
          }
        }
      }
    }
    File(Platform.environment['ICARUS_ROOF_PROBE_OUTPUT'] ??
            'work/systematic-map-review/focused/roof-selection-probe.json')
        .writeAsStringSync(
            '${const JsonEncoder.withIndent('  ').convert(result)}\n');
  });
}
