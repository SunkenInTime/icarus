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
