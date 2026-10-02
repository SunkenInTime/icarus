import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/replay/replay_map_projection.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';

const _degrees = math.pi / 180;

void _expectOffset(Offset actual, Offset expected, {double tolerance = 1e-3}) {
  expect(actual.dx, closeTo(expected.dx, tolerance), reason: '$actual');
  expect(actual.dy, closeTo(expected.dy, tolerance), reason: '$actual');
}

double _wrap(double radians) => (radians + math.pi) % (2 * math.pi) - math.pi;

void main() {
  setUp(() => CoordinateSystem(playAreaSize: const Size(1920, 1080)));

  group('forMapPath', () {
    test('knows every Icarus map by its /Game/Maps/ codename', () {
      const paths = {
        '/Game/Maps/Ascent/Ascent': MapValue.ascent,
        '/Game/Maps/Duality/Duality': MapValue.bind,
        '/Game/Maps/Triad/Triad': MapValue.haven,
        '/Game/Maps/Bonsai/Bonsai': MapValue.split,
        '/Game/Maps/Port/Port': MapValue.icebox,
        '/Game/Maps/Foxtrot/Foxtrot': MapValue.breeze,
        '/Game/Maps/Canyon/Canyon': MapValue.fracture,
        '/Game/Maps/Pitt/Pitt': MapValue.pearl,
        '/Game/Maps/Jam/Jam': MapValue.lotus,
        '/Game/Maps/Juliett/Juliett': MapValue.sunset,
        '/Game/Maps/Infinity/Infinity': MapValue.abyss,
        '/Game/Maps/Rook/Rook': MapValue.corrode,
        '/Game/Maps/Plummet/Plummet': MapValue.summit,
      };
      for (final MapEntry(key: path, value: map) in paths.entries) {
        expect(ReplayMapProjection.forMapPath(path)?.map, map, reason: path);
      }
      expect(paths.values.toSet(), MapValue.values.toSet());
    });

    test('is null for maps Icarus does not have', () {
      expect(
          ReplayMapProjection.forMapPath('/Game/Maps/Poveglia/Range'), isNull);
      expect(
          ReplayMapProjection.forMapPath(
              '/Game/Maps/HURM/HURM_Alley/HURM_Alley'),
          isNull);
      expect(ReplayMapProjection.forMapPath(''), isNull);
    });
  });

  // Real positions from 13.00 replays, projected independently in Python from
  // the alignment JSON. Each lands on walkable floor of the attack SVG.
  test('pins real replay landmarks on the four maps with replays', () {
    const pins = [
      // Spike spawns are in the attacker spawn; plants are on B site.
      (
        MapValue.sunset,
        -5084.60009765625,
        514.9000244140625,
        Offset(222.3767, 420.6966)
      ),
      (MapValue.sunset, 566.5, -4499.39990234375, Offset(48.0184, 224.1953)),
      (MapValue.lotus, 1175.0, 800.0, Offset(256.948, 418.7609)),
      (
        MapValue.lotus,
        6946.2001953125,
        -383.8999938964844,
        Offset(209.1716, 185.8635)
      ),
      (MapValue.split, 1950.0, 400.0, Offset(214.7821, 429.4453)),
      (MapValue.split, -2221.800048828125, -6302.5, Offset(51.6806, 167.403)),
      (MapValue.summit, 1039.0, 5900.0, Offset(205.0441, 418.4595)),
      (
        MapValue.summit,
        8772.2001953125,
        1589.4000244140625,
        Offset(58.6078, 155.7533)
      ),
    ];
    for (final (map, x, y, svg) in pins) {
      _expectOffset(ReplayMapProjection.forMap(map).attackSvgPoint(x, y), svg);
    }
  });

  test('pins game (1000, 2000) cm on every map', () {
    const pins = {
      MapValue.ascent: Offset(194.5062, 448.6947),
      MapValue.breeze: Offset(273.2865, 365.8105),
      MapValue.lotus: Offset(305.3741, 425.8231),
      MapValue.icebox: Offset(73.7552, 201.8967),
      MapValue.sunset: Offset(274.0169, 209.1216),
      MapValue.split: Offset(177.6407, 491.9992),
      MapValue.haven: Offset(166.0457, 583.8712),
      MapValue.fracture: Offset(351.7027, 530.862),
      MapValue.abyss: Offset(264.0622, 311.9456),
      MapValue.pearl: Offset(299.1495, 396.2057),
      MapValue.bind: Offset(280.4242, 433.0389),
      MapValue.corrode: Offset(225.217, 308.8952),
      MapValue.summit: Offset(72.5564, 419.7843),
    };
    for (final MapEntry(key: map, value: svg) in pins.entries) {
      _expectOffset(
          ReplayMapProjection.forMap(map).attackSvgPoint(1000, 2000), svg);
    }
  });

  group('on every map', () {
    for (final map in MapValue.values) {
      test('$map: world point is where the app draws the SVG point', () {
        final projection = ReplayMapProjection.forMap(map);
        final transform = SvgHeightMapTransform.forMap(map);
        final coordinates = CoordinateSystem.instance;
        for (final (x, y) in const [
          (0.0, 0.0),
          (1000.0, 2000.0),
          (-3500.0, 4200.0)
        ]) {
          final world = projection.toWorld(x, y);
          _expectOffset(
              world,
              transform.sideWorldFromSource(projection.attackSvgPoint(x, y),
                  isAttack: true),
              tolerance: 1e-9);
          // The defense view of the saved point is the defense SVG point.
          final defenseWorld = coordinates.positionForSide(
              canonicalPosition: world,
              reflectionOffset: Offset.zero,
              isAttack: false);
          _expectOffset(
              transform.sourceFromSideWorld(defenseWorld, isAttack: false),
              projection.defenseSvgPoint(x, y),
              tolerance: 1e-9);
        }
      });

      test('$map: game to map is a turn and a uniform scale, never a mirror',
          () {
        final projection = ReplayMapProjection.forMap(map);
        final origin = projection.toWorld(0, 0);
        final alongX = projection.toWorld(100, 0) - origin;
        final alongY = projection.toWorld(0, 100) - origin;
        expect(alongX.distance, closeTo(alongY.distance, 1e-9));
        expect(alongX.dx * alongY.dx + alongX.dy * alongY.dy, closeTo(0, 1e-9));
        // Seen from above, Unreal's +X to +Y turns clockwise, as on screen.
        expect(alongX.dx * alongY.dy - alongX.dy * alongY.dx, greaterThan(0));
        expect(projection.worldLength(100), closeTo(alongX.distance, 1e-9));
      });

      test('$map: rotation points the way the yaw moves the player', () {
        final projection = ReplayMapProjection.forMap(map);
        for (var yaw = 0.0; yaw < 360; yaw += 15) {
          final step = projection.toWorld(1000 * math.cos(yaw * _degrees),
                  1000 * math.sin(yaw * _degrees)) -
              projection.toWorld(0, 0);
          // A drag toward screen direction (dx, dy) saves atan2 + pi / 2.
          final expected = math.atan2(step.dy, step.dx) + math.pi / 2;
          expect(_wrap(projection.rotationForYaw(yaw) - expected),
              closeTo(0, 1e-9),
              reason: 'yaw $yaw');
        }
      });
    }
  });

  group('rotationForYaw on real replay movement', () {
    // A player running straight out of Split's attacker spawn, replay
    // c8989335 at 1188.5 s to 1189.3 s: x stays 1950 while y falls from 472
    // to 42, yaw 270. On screen they run straight up, rotation 0.
    test('Split attacker spawn corridor, looking up the screen', () {
      final projection = ReplayMapProjection.forMap(MapValue.split);
      final start = projection.toWorld(1950, 472.1);
      final end = projection.toWorld(1950, 41.79);
      expect(end.dx, closeTo(start.dx, 1e-9));
      expect(end.dy, lessThan(start.dy));
      expect(_wrap(projection.rotationForYaw(270)), closeTo(0, 1e-9));
    });

    // Replay 1fb53a2c at 741.0 s to 742.0 s: running up Summit's attacker
    // spawn corridor along +X at yaw 0.09 then 359.94.
    test('Summit attacker spawn corridor, looking up the screen', () {
      final projection = ReplayMapProjection.forMap(MapValue.summit);
      final start = projection.toWorld(764.47, 6200.72);
      final end = projection.toWorld(1438.95, 6203.13);
      expect(end.dy, lessThan(start.dy));
      expect((end.dx - start.dx).abs(), lessThan(0.1 * (start.dy - end.dy)));
      expect(_wrap(projection.rotationForYaw(0.093384)).abs(), lessThan(0.01));
      expect(_wrap(projection.rotationForYaw(359.93958)).abs(), lessThan(0.01));
    });

    // Replay c8313344 at 16.0 s to 17.3 s: leaving Sunset's attacker spawn
    // up and to the left at yaw 320.6, which on screen is 39.4 degrees
    // anticlockwise of straight up.
    test('Sunset leaving attacker spawn, looking up and left', () {
      final projection = ReplayMapProjection.forMap(MapValue.sunset);
      final start = projection.toWorld(-4621.59, 719.23);
      final end = projection.toWorld(-3968.47, 185.04);
      final travelled = end - start;
      final rotation = projection.rotationForYaw(320.614);
      expect(rotation, closeTo(-39.386 * _degrees, 1e-3));
      expect(
          _wrap(math.atan2(travelled.dy, travelled.dx) + math.pi / 2 - rotation)
              .abs(),
          lessThan(2 * _degrees));
    });
  });

  test('defense rotation is the canonical rotation turned half way', () {
    // Saved rotations are canonical; the defense view adds pi, matching the
    // half turn that takes the attack SVG to the defense SVG.
    final projection = ReplayMapProjection.forMap(MapValue.split);
    final a = projection.defenseSvgPoint(1950, 472.1);
    final b = projection.defenseSvgPoint(1950, 41.79);
    final travelled = b - a;
    final defenseRotation = CoordinateSystem.instance
        .rotationForSide(projection.rotationForYaw(270), isAttack: false);
    expect(
        _wrap(math.atan2(travelled.dy, travelled.dx) +
                math.pi / 2 -
                defenseRotation)
            .abs(),
        lessThan(1e-9));
  });
}
