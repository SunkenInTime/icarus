import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Path;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

Map<String, dynamic> asset(String name, String side) {
  final folder = const bool.fromEnvironment('ICARUS_VERIFY_BUNDLED_GAMEPLAY')
      ? null
      : Platform.environment['ICARUS_SIGHTLINE_MODELS'];
  final path = folder == null
      ? 'assets/maps/${name}_svg_height_$side.json.gz'
      : '$folder/$name-$side.json.gz';
  return jsonDecode(utf8.decode(gzip.decode(File(path).readAsBytesSync())));
}

Offset point(dynamic xy) =>
    Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble());

void main() {
  final fixture = jsonDecode(
      File('test/fixtures/reported_sightlines_2026_09_12.json')
          .readAsStringSync());
  for (final name in ['abyss', 'haven']) {
    for (final side in ['attack', 'defense']) {
      test(
          '$name $side preserves the reported walls, openings and standing levels',
          () {
        final model = SvgHeightVisibility.fromJson(asset(name, side));
        final rows = fixture['maps'][name];
        for (final row in [...rows['poses'], ...rows['rampPath']]) {
          final origin = point(row['positions'][side]);
          final support = model.automaticSupportAt(origin);
          final floor = support?.surfaceElevationAt(origin) ??
              model.ground!.heightAt(origin);
          expect(floor, closeTo(row['expectedFloor'], .02),
              reason: '${row["id"] ?? "ramp path"} $origin');
          for (final ray in row['rays'] ?? []) {
            final delta = point(ray['targets'][side]) - origin;
            final hit = model.castRay(
                origin: origin,
                directionRadians: math.atan2(delta.dy, delta.dx),
                range: delta.distance,
                supportId: support?.id);
            expect(hit == null, ray['visible'],
                reason:
                    '${row["id"]} to ${ray["targets"][side]} hit ${hit?.wallId}');
          }
        }
        if (name == 'haven') {
          final tower = point(rows['poses'][0]['positions'][side]);
          final lower =
              model.standingSupportAt(tower, savedEyeElevationCm: 475);
          expect(
              lower?.surfaceElevationAt(tower) ?? model.ground!.heightAt(tower),
              closeTo(3, .02));
          expect(model.automaticSupportAt(tower)!.surfaceElevationAt(tower),
              closeTo(9, .02));
          for (final ray in rows['towerLowerRays']) {
            final delta = point(ray['targets'][side]) - tower;
            expect(
                model.castRay(
                        origin: tower,
                        directionRadians: math.atan2(delta.dy, delta.dx),
                        range: delta.distance,
                        absoluteEyeElevationMeters: 4.75) ==
                    null,
                ray['visible'],
                reason: 'Lower tower passage ${ray["targets"][side]}');
          }
          final reverse = rows['reverseWindow'];
          final origin = point(reverse['positions'][side]);
          final target = point(reverse['targets'][side]);
          final delta = target - origin;
          final cone = model.cone(
              origin: origin,
              directionRadians: math.atan2(delta.dy, delta.dx),
              range: 100,
              apertureRadians: math.pi / 2,
              supportId: model.automaticSupportAt(origin)?.id);
          expect(
              (cone.visibilityPath ?? (Path()..addPolygon(cone.polygon, true)))
                  .contains(target),
              isTrue);
          // The September 13 gameplay simplification omits sill occlusion.
          // A single horizontal cone now crosses the window.
          expect(
              model.castRay(
                  origin: origin,
                  directionRadians: math.atan2(delta.dy, delta.dx),
                  range: delta.distance),
              isNull);
        }
      });
    }
  }

  test('sightline floors reject unknown, duplicate and sloped references', () {
    for (final ids in [
      ['missing-floor'],
      ['haven-measured-volume-362-0', 'haven-measured-volume-362-0']
    ]) {
      final data = asset('haven', 'attack')..['sightlineFloorSupportIds'] = ids;
      expect(() => SvgHeightVisibility.fromJson(data), throwsFormatException);
    }
    final data = asset('haven', 'attack')
      ..['sightlineFloorSupportIds'] = ['haven-measured-volume-362-0'];
    final support = (data['supports'] as List)
        .singleWhere((row) => row['id'] == 'haven-measured-volume-362-0');
    support['surfacePlane'] = [.1, 0.0, 3.0];
    expect(() => SvgHeightVisibility.fromJson(data), throwsFormatException);
  });
}
