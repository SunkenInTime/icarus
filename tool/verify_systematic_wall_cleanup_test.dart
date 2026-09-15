import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

SvgHeightVisibility load(String path) => SvgHeightVisibility.fromJson(
    jsonDecode(utf8.decode(gzip.decode(File(path).readAsBytesSync()))));

void main() {
  test('all-map numerical cleanup preserves data and removes phantom contacts',
      () {
    const root = 'work/systematic-map-review';
    final records = jsonDecode(
            File('$root/numerical-candidate/removals.json').readAsStringSync())
        as List;
    final results = <Map<String, dynamic>>[];
    for (final row in records) {
      final name = row['map'] as String;
      final side = row['side'] as String;
      final beforePath = '$root/numerical-candidate/$name/before-$side.json.gz';
      final afterPath =
          '$root/numerical-candidate/$name/candidate-$side.json.gz';
      Map data(String path) =>
          jsonDecode(utf8.decode(gzip.decode(File(path).readAsBytesSync())))
              as Map;
      final original = data(beforePath);
      final candidate = data(afterPath);
      for (final key in original.keys.where((k) => k != 'walls')) {
        expect(candidate[key], original[key], reason: '$name $side $key');
      }
      final removed = (row['removed'] as List).map((r) => r['wallId']).toSet();
      expect(
          candidate['walls'],
          (original['walls'] as List)
              .where((w) => !removed.contains(w['id']))
              .toList());
      if (removed.isEmpty) continue;
      final before = load(beforePath);
      final after = load(afterPath);
      final report =
          jsonDecode(File('$root/walls/$name.json').readAsStringSync());
      final walls = {
        for (final w in original['walls'] as List) w['id'] as String: w
      };
      for (final residue in report['residue'] as List) {
        if (residue['side'] != side) continue;
        final wall = walls[residue['wallId']]!;
        var longest = Offset.zero;
        for (final ring in wall['rings'] as List) {
          for (var i = 0; i + 3 < ring.length; i += 2) {
            final delta = Offset(
                (ring[i + 2] as num).toDouble() - (ring[i] as num).toDouble(),
                (ring[i + 3] as num).toDouble() -
                    (ring[i + 1] as num).toDouble());
            if (delta.distanceSquared > longest.distanceSquared)
              longest = delta;
          }
        }
        if (longest.distance == 0) continue;
        final normal = Offset(-longest.dy, longest.dx) / longest.distance;
        for (final sample in residue['novelBlockingSamples'] as List) {
          final xy = sample['svg'] as List;
          final p =
              Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble());
          final eye = (sample['eyeMeters'] as num).toDouble();
          for (final sign in [-1.0, 1.0]) {
            final origin = p - normal * (.05 * sign);
            final direction = normal * sign;
            final angle = math.atan2(direction.dy, direction.dx);
            SvgVisibilityHit? cast(SvgHeightVisibility m) => m.castRay(
                origin: origin,
                directionRadians: angle,
                range: .1,
                absoluteEyeElevationMeters: eye);
            final oldHit = cast(before);
            final newHit = cast(after);
            // Removing a zero-area remnant must not introduce a blocker.
            expect(oldHit == null && newHit != null, isFalse,
                reason: '$name $side ${residue['wallId']}');
            results
                .add(dict(name, side, residue['wallId'], eye, oldHit, newHit));
          }
        }
      }
    }
    final changed = results
        .where((r) => r['beforeWall'] != null && r['afterWall'] == null)
        .length;
    expect(changed, greaterThan(0),
        reason: 'The check must exercise an actual phantom blocker.');
    File('$root/numerical-candidate/runtime-verification.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
      'status': 'passed',
      'queries': results.length,
      'clearedPhantomContacts': changed,
      'scope':
          'Production Dart ray caster at diagnostic absolute heights; these are geometric controls, not gameplay eligibility claims.',
      'records': results,
    }));
  });
}

Map<String, dynamic> dict(String name, String side, dynamic wall, double eye,
        SvgVisibilityHit? before, SvgVisibilityHit? after) =>
    {
      'map': name,
      'side': side,
      'removedWall': wall,
      'eyeMeters': eye,
      'beforeWall': before?.wallId,
      'afterWall': after?.wallId
    };
