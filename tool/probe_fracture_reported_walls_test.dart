import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  test('record Fracture screenshot floor, wall and native cone diagnostics',
      () {
    const root = 'work/fracture-wall-review-2026-09-14';
    final candidate = Platform.environment['ICARUS_FRACTURE_WALL_MODELS'];
    final fixture = jsonDecode(
        File('$root/screenshot-probe-input.json').readAsStringSync());
    final results = <Map<String, dynamic>>[];
    for (final side in ['attack', 'defense']) {
      final model = SvgHeightVisibility.fromJson(jsonDecode(utf8.decode(
          gzip.decode(File(candidate == null
                  ? '$root/before-$side.json.gz'
                  : '$candidate/candidate-$side.json.gz')
              .readAsBytesSync()))));
      for (final row in fixture as List) {
        final xy = row['svg'][side];
        final origin =
            Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble());
        final direction = (row['directionAttack'] as num).toDouble() +
            (side == 'attack' ? 0 : math.pi);
        Map<String, dynamic> state(Offset p) {
          final support = model.standingSupportAt(p);
          final eye =
              (support?.surfaceElevationAt(p) ?? model.ground!.heightAt(p))! +
                  1.75;
          return {
            'svg': [p.dx, p.dy],
            'ground': model.ground!.heightAt(p),
            'physicalGround': model.ground!.standingHeightAt(p),
            'selectedSupport': support?.id,
            'eye': eye,
            'receiver': model.receiverContains(p),
            'containingWalls': [
              for (final wall in model.walls.where((w) => w.contains(p)))
                {
                  'id': wall.id,
                  'active': wall.blocks(eye),
                  'floor': wall.floorElevationMeters,
                  'bands': [
                    for (final b in wall.bands) [b.bottom, b.top]
                  ]
                }
            ],
            'localSupports': [
              for (final s in model.supportsAt(p))
                {
                  'id': s.id,
                  'floor': s.surfaceElevationAt(p),
                  'automatic': s.automaticStandingAllowed
                }
            ],
          };
        }

        final support = model.standingSupportAt(origin);
        model.closeNativeAcceleration();
        final dart = model.cone(
            origin: origin,
            directionRadians: direction,
            range: 90,
            apertureRadians: math.pi / 3,
            supportId: support?.id);
        expect(
            model.enableNativeAcceleration(
                libraryPath:
                    'build/reopened-map-review/runner/Profile/icarus_height.dll'),
            isTrue);
        final native = model.cone(
            origin: origin,
            directionRadians: direction,
            range: 90,
            apertureRadians: math.pi / 3,
            supportId: support?.id);
        final rays = [];
        for (var angle = 0; angle < 360; angle += 2) {
          final hit = model.castRay(
              origin: origin,
              directionRadians: angle * math.pi / 180,
              range: 90,
              supportId: support?.id);
          rays.add({
            'degrees': angle,
            'wall': hit?.wallId,
            'distance': hit?.distance,
            'position': hit == null ? null : [hit.point.dx, hit.point.dy]
          });
        }
        results.add({
          'screenshot': row['screenshot'],
          'side': side,
          'origin': state(origin),
          'direction': direction,
          'dartEye': dart.eyeElevationMeters,
          'nativeEye': native.eyeElevationMeters,
          'dartPolygon': [
            for (final p in dart.polygon) [p.dx, p.dy]
          ],
          'nativePolygon': [
            for (final p in native.polygon) [p.dx, p.dy]
          ],
          'rays': rays,
          'neighborhood': [
            for (final dx in [-1.0, -.5, 0.0, .5, 1.0])
              for (final dy in [-1.0, -.5, 0.0, .5, 1.0])
                state(origin + Offset(dx, dy))
          ]
        });
      }
      model.closeNativeAcceleration();
    }
    File(candidate == null
            ? '$root/runtime-probe.json'
            : '$candidate/runtime-probe.json')
        .writeAsStringSync(
            '${const JsonEncoder.withIndent('  ').convert(results)}\n');
  });
}
