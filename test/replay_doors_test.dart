import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/map_doors.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/replay/replay_cone_worker.dart';
import 'package:icarus/replay/replay_doors.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_frame.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';

import 'replay_test_support.dart';

/// Lotus: the C door spinning from 20 s, the A Link wall breaking at 30 s, in
/// a first round of 0 to 60 s. Summit's mid wall, on the same rows, drops from
/// 40 s to 41.75 s.
ReplayDocument document({List<Map<String, Object?>>? doors}) =>
    ReplayDocument.fromBytes(icrp({
      ...sampleJson(),
      'rounds': [
        {'index': 0, 'startMs': 0, 'endMs': 60000, 'attackingTeam': 'Red'},
        {'index': 1, 'startMs': 60000, 'endMs': 120000, 'attackingTeam': 'Red'},
      ],
      'doors': doors ??
          [
            {'actor': 'Drawbridge5', 'startMs': 20000, 'endMs': 30000},
            {'actor': 'RespawningWallPlate', 'startMs': 30000, 'endMs': 30000},
            {'actor': 'DescentBox_v9', 'startMs': 40000, 'endMs': 41750},
          ],
    }));

void main() {
  final doc = document();
  ReplayRound round(int timeMs) => doc.roundAt(timeMs)!;

  group('a Lotus door', () {
    final doors = ReplayDoors(doc, MapValue.lotus);

    test('is at rest until its spin starts', () {
      expect(doors.at(19999, round(19999)), isEmpty);
    });

    test('turns half way round over the spin', () {
      expect(doors.at(25000, round(25000))['lotus-c'], 1);
      expect(doors.at(30000, round(30000))['lotus-c'], 2);
    });

    test('is at rest again once it stops', () {
      expect(doors.at(30001, round(30001)).containsKey('lotus-c'), isFalse);
    });

    test('a move longer than a spin still turns only half way', () {
      final long = ReplayDoors(
        document(doors: [
          {'actor': 'Drawbridge5', 'startMs': 20000, 'endMs': 31500},
        ]),
        MapValue.lotus,
      );

      expect(long.at(31000, round(31000))['lotus-c'], 2);
    });

    test('a spin cut short keeps its pace', () {
      final late = ReplayDoors(
        document(doors: [
          {'actor': 'Drawbridge5', 'startMs': 56000, 'endMs': 60001},
        ]),
        MapValue.lotus,
      );

      expect(late.at(59000, round(59000))['lotus-c'], closeTo(0.6, 1e-9));
    });
  });

  group('the A Link wall', () {
    final doors = ReplayDoors(doc, MapValue.lotus);

    test('stays broken for the round', () {
      expect(doors.at(29999, round(29999)), isNot(contains('lotus-a-link')));
      expect(doors.at(59000, round(59000))['lotus-a-link'], 1);
    });

    test('is whole again next round', () {
      expect(doors.at(60000, round(60000)), isEmpty);
    });
  });

  group('a Summit wall', () {
    final doors = ReplayDoors(doc, MapValue.summit);

    test('drops at the pace of its move', () {
      expect(doors.at(40875, round(40875))['summit-mid'], closeTo(0.5, 1e-9));
    });

    test('stays down for the round and resets for the next', () {
      expect(doors.at(50000, round(50000))['summit-mid'], 1);
      expect(doors.at(61000, round(61000)), isEmpty);
    });
  });

  group('an Ascent door', () {
    // As Sunset's door in a 13.00 replay: shut at 10 s, open again at 30 s,
    // shut at 45 s and still shut as the round ends.
    final ascent = document(doors: [
      {'actor': 'WindowShieldB1', 'startMs': 10000, 'endMs': 15000},
      {
        'actor': 'WindowShieldB1',
        'startMs': 30000,
        'endMs': 35000,
        'toRest': true,
      },
      {'actor': 'WindowShieldB1', 'startMs': 45000, 'endMs': 50000},
    ]);
    final doors = ReplayDoors(ascent, MapValue.ascent);
    ReplayRound round(int timeMs) => ascent.roundAt(timeMs)!;

    test('is open until it starts to shut', () {
      expect(doors.at(9999, round(9999)), isEmpty);
    });

    test('shuts at the pace of its move and stays shut', () {
      expect(doors.at(12500, round(12500))['ascent-b'], closeTo(0.5, 1e-9));
      expect(doors.at(29999, round(29999))['ascent-b'], 1);
    });

    test('opens again at the pace of its move', () {
      expect(doors.at(31000, round(31000))['ascent-b'], closeTo(0.8, 1e-9));
      expect(doors.at(35000, round(35000)), isEmpty);
      expect(doors.at(44999, round(44999)), isEmpty);
    });

    test("stays shut to the round's end and opens for the next", () {
      expect(doors.at(59000, round(59000))['ascent-b'], 1);
      expect(doors.at(60000, round(60000)), isEmpty);
    });

    test('cuts cones once it is half way down', () {
      final ids = [for (final door in mapDoorsOf(MapValue.ascent)) door.id];

      expect(replayDoorsOfMask(ids, doors.mask({'ascent-b': 0.4})), isEmpty);
      expect(
        replayDoorsOfMask(ids, doors.mask({'ascent-b': 0.5})),
        {'ascent-b'},
      );
    });
  });

  test('a move reads as away from rest unless it says', () {
    final moves = document(doors: [
      {'actor': 'WindowShieldA1', 'startMs': 1, 'endMs': 2},
      {'actor': 'WindowShieldA1', 'startMs': 3, 'endMs': 4, 'toRest': true},
    ]).doors;

    expect([for (final move in moves) move.toRest], [false, true]);
  });

  test("another map's actors don't reach a map", () {
    final abyss = ReplayDoors(
      document(doors: [
        {'actor': 'RespawningWallPlate', 'startMs': 30000, 'endMs': 30000},
      ]),
      MapValue.abyss,
    );

    expect(abyss.at(40000, round(40000)), isEmpty);
  });

  test('a time before any round has no doors', () {
    expect(ReplayDoors(doc, MapValue.lotus).at(25000, null), isEmpty);
  });

  test('a document from before doors reads as none', () {
    final old = ReplayDocument.fromBytes(icrp(sampleJson()));

    expect(old.doors, isEmpty);
  });

  test('a mask names the doors it was made from', () {
    final doors = ReplayDoors(doc, MapValue.lotus);
    final ids = [for (final door in mapDoorsOf(MapValue.lotus)) door.id];

    final mask = doors.mask({'lotus-c': 1, 'lotus-a-link': 1});

    expect(replayDoorsOfMask(ids, mask), {'lotus-c', 'lotus-a-link'});
    expect(doors.mask(const {}), 0);
  });

  test("a spinning door cuts cones in the pose it's drawn nearer", () {
    final doors = ReplayDoors(doc, MapValue.lotus);
    final ids = [for (final door in mapDoorsOf(MapValue.lotus)) door.id];
    Set<String> cut(double amount) =>
        replayDoorsOfMask(ids, doors.mask({'lotus-c': amount}));

    expect(cut(0.2), isEmpty);
    expect(cut(0.5), {'lotus-c'});
    expect(cut(1.4), {'lotus-c'});
    expect(cut(1.6), isEmpty);
  });

  group('a capture', () {
    ReplayFrame frame(Map<String, double> doors) => ReplayFrame(
          timeMs: 0,
          round: null,
          isAttack: true,
          agents: const [],
          abilities: const [],
          utilities: const [],
          doors: doors,
        );

    test('saves a row for each door changed, part way or not', () {
      final rows = frame({'lotus-c': 0.4, 'lotus-a-link': 1}).doorRows;

      expect(
        rows.map((row) => row.mapDoor),
        unorderedEquals(['lotus-c', 'lotus-a-link']),
      );
      expect(rows.map((row) => row.id).toSet(), hasLength(2));
    });

    test('saves nothing for doors at rest', () {
      expect(frame(const {}).doorRows, isEmpty);
    });
  });

  test('the worker cuts cones against a replay\'s doors', () async {
    final worker = await ReplayConeWorker.start(
      map: MapValue.lotus,
      attackModel: Uint8List.fromList(
        File('assets/maps/lotus_svg_height_attack.json.gz').readAsBytesSync(),
      ),
      defenseModel: Uint8List.fromList(
        File('assets/maps/lotus_svg_height_defense.json.gz').readAsBytesSync(),
      ),
    );
    addTearDown(worker.dispose);
    final door = mapDoors.firstWhere((door) => door.id == 'lotus-a-link');
    final transform = SvgHeightMapTransform.forMap(MapValue.lotus);
    final (from, to) = door.worldLine();
    final middle = transform.sourceFromSideWorld(
      (from + to) / 2,
      isAttack: true,
    );
    final doors = ReplayDoors(doc, MapValue.lotus);
    Future<double> reach(int mask) async {
      final eye = middle + const Offset(8, 0);
      final result = await worker.cut(ReplayConeRequest(
        isAttack: true,
        origin: eye,
        directionRadians: math.pi,
        range: 40,
        apertureRadians: 0.2,
        doors: mask,
      ));
      return result.cone!.polygon
          .map((point) => (point - eye).distance)
          .reduce(math.max);
    }

    final whole = await reach(0);
    final broken = await reach(doors.mask({'lotus-a-link': 1}));

    expect(whole, lessThan(10));
    expect(broken, greaterThan(whole + 5));
  });
}
