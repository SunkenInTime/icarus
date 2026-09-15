import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

Map<String, dynamic> breezeData(String side) {
  final folder = const bool.fromEnvironment('ICARUS_VERIFY_BUNDLED_GAMEPLAY')
      ? null
      : Platform.environment['ICARUS_BREEZE_MODELS'];
  final path = folder == null
      ? 'assets/maps/breeze_svg_height_$side.json.gz'
      : '$folder/candidate-$side.json.gz';
  return jsonDecode(utf8.decode(gzip.decode(File(path).readAsBytesSync())));
}

// Frozen source alignment, not a rounded reflection of the SVG view box.
Offset breezePoint(String side, double x, double y) =>
    side == 'attack' ? Offset(x, y) : Offset(446.934 - x, 473 - y);

double floorAt(SvgHeightVisibility model, Offset origin) =>
    model.automaticSupportAt(origin)?.surfaceElevationAt(origin) ??
    model.ground!.heightAt(origin)!;

bool visible(SvgHeightVisibility model, Offset origin, Offset target) {
  final delta = target - origin;
  return model.castRay(
          origin: origin,
          directionRadians: math.atan2(delta.dy, delta.dx),
          range: delta.distance,
          supportId: model.automaticSupportAt(origin)?.id) ==
      null;
}

void main() {
  for (final side in ['attack', 'defense']) {
    test('Breeze $side stays in the passage beneath the overhead box', () {
      final model = SvgHeightVisibility.fromJson(breezeData(side));
      // Source volume 581 is the 4 m passage floor. Volume 583 hangs above it
      // from 8 to 16 m; its upper face is not the reported gameplay position.
      for (var x = 268.0; x <= 278; x += .5) {
        for (var y = 264.5; y <= 275; y += .5) {
          final origin = breezePoint(side, x, y);
          expect(floorAt(model, origin), closeTo(4, .02),
              reason: 'Passage $side $origin');
        }
      }
    });

    test('Breeze $side box keeps its height without opening facade holes', () {
      final model = SvgHeightVisibility.fromJson(breezeData(side));
      // This entire square lies in the independently measured volume-626-0 top.
      for (var x = 345.75; x <= 346.75; x += .25) {
        for (var y = 175.125; y <= 176.125; y += .25) {
          final origin = breezePoint(side, x, y);
          expect(floorAt(model, origin), closeTo(9, .02));
          for (final target in [
            breezePoint(side, 299, 233),
            breezePoint(side, 310, 219),
            breezePoint(side, 299, 240),
          ]) {
            expect(visible(model, origin, target), isFalse,
                reason: 'The continuous facade blocks $origin to $target');
          }
          expect(visible(model, origin, breezePoint(side, 346, 198)), isTrue,
              reason: 'Preserve the open approach in front of the box.');
        }
      }
    });

    test('Breeze $side regression detects a false low facade section', () {
      final data = breezeData(side);
      for (final wall in data['walls']) {
        if ((wall['id'] as String).contains('-facade-')) {
          wall['bands'] = [
            [0.0, 9.0]
          ];
        }
      }
      final bad = SvgHeightVisibility.fromJson(data);
      expect(
          visible(bad, breezePoint(side, 345.75, 175.125),
              breezePoint(side, 299, 240)),
          isTrue);
    });

    test('Breeze $side regression rejects a reintroduced overhead standing top',
        () {
      final data = breezeData(side);
      final points = [
        breezePoint(side, 267.2, 264.1),
        breezePoint(side, 278.5, 264.1),
        breezePoint(side, 278.5, 275.9),
        breezePoint(side, 267.2, 275.9),
      ];
      (data['supports'] as List).add({
        'id': 'fault-overhead-top',
        'label': 'Fault control',
        'rings': [
          points.expand((p) => [p.dx, p.dy]).toList()
        ],
        'fillRule': 'evenodd',
        'floorElevationMeters': 0.0,
        'heightAboveFloorMeters': 16.0,
        'surfaceElevationMeters': 16.0,
        'automaticStandingAllowed': true,
      });
      final bad = SvgHeightVisibility.fromJson(data);
      expect(floorAt(bad, breezePoint(side, 276.875, 265)),
          isNot(closeTo(4, .02)));
    });
  }
}
