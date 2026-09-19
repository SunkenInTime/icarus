import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

SvgHeightVisibility loadFocusedMap(String name, String side) {
  final folder = const bool.fromEnvironment('ICARUS_VERIFY_BUNDLED_GAMEPLAY')
      ? null
      : Platform.environment['ICARUS_FOCUSED_MODELS'];
  final path = folder == null
      ? 'assets/maps/${name}_svg_height_$side.json.gz'
      : '$folder/$name/candidate-$side.json.gz';
  return SvgHeightVisibility.fromJson(
      jsonDecode(utf8.decode(gzip.decode(File(path).readAsBytesSync()))));
}

Offset focusedPoint(String name, String side, double x, double y) {
  if (side == 'attack') return Offset(x, y);
  const origins = {
    'abyss': Offset(453.5177, 472.806),
    'haven': Offset(392.991, 473),
    'breeze': Offset(446.934, 473),
    'icebox': Offset(387.459, 473),
    'pearl': Offset(468.6677, 473),
  };
  return origins[name]! - Offset(x, y);
}

double focusedFloor(SvgHeightVisibility model, Offset origin) =>
    model.automaticSupportAt(origin)?.surfaceElevationAt(origin) ??
    model.ground!.heightAt(origin)!;

void main() {
  for (final side in ['attack', 'defense']) {
    test('Bind $side excludes the map-wide player kill-volume cap', () {
      final model = loadFocusedMap('bind', side);
      for (final id in [
        'bind-physical-top-a3491fb95d39',
        'bind-measured-volume-748-0',
      ]) {
        expect(model.supports.any((s) => s.id == id), isFalse);
      }
      // This sloped bridge has a 106 m plane intercept, but its local
      // elevation is around 5.9 m. Preserve its measured standing face.
      final bridge = side == 'attack'
          ? const Offset(93.47635692235252, 140.3427945650153)
          : const Offset(321.7016430776475, 333.6572054349847);
      expect(focusedFloor(model, bridge), closeTo(5.595978281650005, .02));
    });

    test('Abyss $side stays below the B Tower and Mid ceiling bodies', () {
      final model = loadFocusedMap('abyss', side);
      // Independent collision floor domains 251/1720/1724 are 10 m;
      // Mid volume 29 is 8 m. The overhead tops are 19.955 and 19.5 m.
      for (final pose in [
        [14.98106812474244, 156.27415960169313, 10.0],
        [14.29625960371, 155.69173776172386, 10.0],
        [13.141556308336352, 154.87540247172387, 10.0],
        [225.9564341680997, 213.964137115, 8.0],
      ]) {
        expect(
            focusedFloor(model, focusedPoint('abyss', side, pose[0], pose[1])),
            closeTo(pose[2], .02));
      }
      for (final id in [
        'abyss-physical-top-81282b4711a7',
        'abyss-physical-top-9a0b54cf4ee7',
        'abyss-physical-top-b0a70da84d02',
        'abyss-measured-volume-145-0',
        'abyss-measured-volume-146-0',
        'abyss-measured-volume-1603-0',
      ]) {
        expect(model.supports.any((support) => support.id == id), isFalse);
      }
    });

    test('Haven $side does not stand on the 44 m invisible boundary', () {
      final model = loadFocusedMap('haven', side);
      // Retained source domain volume-324-0 supplies this 3.0285 m floor.
      final origin =
          focusedPoint('haven', side, 316.84682190500075, 226.00429944);
      expect(focusedFloor(model, origin), closeTo(3.0285, .02));
      expect(
          model.supports.any((s) => s.id == 'haven-physical-top-3c90d775b94d'),
          isFalse);
      expect(model.supports.any((s) => s.id == 'haven-measured-volume-215-0'),
          isFalse);
    });

    test('Breeze $side retains both physical bridge parapets', () {
      final model = loadFocusedMap('breeze', side);
      for (final pose in [
        [332.22039633499855, 107.091],
        [331.3490733048431, 121.913],
      ]) {
        expect(
            focusedFloor(model, focusedPoint('breeze', side, pose[0], pose[1])),
            closeTo(10.5, .02));
      }
    });

    test('Icebox $side retains the physical connector railing', () {
      final model = loadFocusedMap('icebox', side);
      final origin =
          focusedPoint('icebox', side, 137.82272660122567, 107.88038965286454);
      expect(focusedFloor(model, origin), closeTo(5.680668, .02));
    });

    test('Pearl $side lower tunnel opens beneath its continuous ceiling', () {
      final model = loadFocusedMap('pearl', side);
      // Tunnel volume 505 supplies the 2.5 m lower floor. Its complete shell
      // has a 6.175 m ceiling; the upper Hall is a separate standing level.
      // The independently measured lower floor spans y=162.2964..177.5625.
      for (var y = 162.5; y <= 177.5; y += .25) {
        final origin = focusedPoint('pearl', side, 141.5, y);
        final target = focusedPoint('pearl', side, 145.0, y);
        final delta = target - origin;
        final lower = model.supportForAbsoluteEyeElevation(origin, 425);
        expect(lower != null || model.isGroundEyeElevation(origin, 425), isTrue,
            reason:
                'The lower tunnel eye must be a real local standing level.');
        SvgVisibilityHit? ray(double eye) => model.castRay(
            origin: origin,
            directionRadians: math.atan2(delta.dy, delta.dx),
            range: delta.distance,
            absoluteEyeElevationMeters: eye);
        expect(ray(4.25), isNull, reason: 'Lower tunnel $side at y=$y');
        expect(ray(6.5), isNotNull,
            reason: 'Keep the overhead structure at y=$y');
      }
      final origin = focusedPoint('pearl', side, 141.5, 160.15);
      final target = focusedPoint('pearl', side, 145, 160.15);
      final delta = target - origin;
      expect(
          model.castRay(
              origin: origin,
              directionRadians: math.atan2(delta.dy, delta.dx),
              range: delta.distance,
              absoluteEyeElevationMeters: 4.25),
          isNotNull,
          reason: 'The tunnel end jamb remains solid.');
    });
  }
}
