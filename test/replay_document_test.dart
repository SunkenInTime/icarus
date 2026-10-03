import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/replay/replay_document.dart';

import 'replay_test_support.dart';

void main() {
  test('reads the container, players, rounds and kills', () {
    final document = ReplayDocument.fromBytes(icrp(sampleJson()));
    expect(document.match.mapPath, '/Game/Maps/Juliett/Juliett');
    expect(document.match.recordedAt, DateTime.utc(2026, 7, 10, 3, 35, 45));
    expect(
        document.players.first.agentId, 'add6443a-41bd-e414-f6ad-e58d267f4e95');
    expect(document.players.first.team, ReplayTeam.red);
    expect(document.rounds.first.endReason, ReplayRoundEnd.defused);
    expect(document.rounds.first.playStartMs, 31000);
    expect(document.rounds.last.playStartMs, 60000);
    expect(document.rounds.last.economyFor('a')?.armor, 50);
    expect(document.kills.map((kill) => kill.timeMs), [40000, 50000]);
    expect(document.quality.transformVerified, isTrue);
  });

  test('rejects other files and other format versions', () {
    expect(
      () => ReplayDocument.fromBytes(
          Uint8List.fromList(utf8.encode('not a replay at all'))),
      throwsFormatException,
    );
    final bytes = icrp(sampleJson());
    ByteData.sublistView(bytes).setUint32(4, 99, Endian.little);
    expect(() => ReplayDocument.fromBytes(bytes), throwsFormatException);
    expect(
      () => ReplayDocument.fromBytes(Uint8List.sublistView(bytes, 0, 20)),
      throwsFormatException,
    );
  });

  test('finds the round at a time', () {
    final document = ReplayDocument.fromBytes(icrp(sampleJson()));
    expect(document.roundAt(0)?.index, 0);
    expect(document.roundAt(59999)?.index, 0);
    expect(document.roundAt(60000)?.index, 1);
  });

  test('vitals hold their last value', () {
    final vitals = ReplayDocument.fromBytes(icrp(sampleJson())).vitals['a']!;
    expect(vitals.at(500), isNull);
    expect(vitals.at(44999)?.health, 100);
    expect(vitals.at(45000)?.health, 40);
    expect(vitals.at(55000)?.health, 0);
    expect(vitals.at(61000)?.armor, 50);
  });

  group('movement', () {
    ReplayMovementTrack track() => ReplayDocument.fromBytes(icrp(
          sampleJson(movement: {
            'a': {'offset': 0, 'count': 4},
          }),
          records: [
            [1000, 0, 0, 0, 350, 0],
            [1100, 100, 0, 0, 10, 10],
            [1200, 200, 0, 0, 10, 10],
            // A long gap: the player was dead.
            [5000, 900, 900, 0, 90, 0],
          ],
        )).movement['a']!;

    test('interpolates position and takes the short way round on yaw', () {
      final pose = track().poseAt(1050)!;
      expect(pose.position.x, closeTo(50, 1e-3));
      expect(pose.yaw, closeTo(360, 1e-3));
      expect(pose.pitch, closeTo(5, 1e-3));
    });

    test('invents nothing across a long gap or outside the track', () {
      final movement = track();
      expect(movement.poseAt(999), isNull);
      expect(movement.poseAt(1300)?.position.x, closeTo(200, 1e-3));
      expect(movement.poseAt(3000), isNull);
      expect(movement.poseAt(5000)?.position.y, closeTo(900, 1e-3));
      expect(movement.poseAt(6000), isNull);
    });

    test('rejects a record range outside the blob', () {
      expect(
        () => ReplayDocument.fromBytes(icrp(
          sampleJson(movement: {
            'a': {'offset': 0, 'count': 5},
          }),
          records: [
            [0, 0, 0, 0, 0, 0],
          ],
        )),
        throwsFormatException,
      );
    });
  });
}
