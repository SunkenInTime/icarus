import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/replay/replay_document.dart';

/// Builds an `.icrp` buffer the way `native/replay` lays it out.
Uint8List icrp(Map<String, Object?> json,
    {List<List<num>> records = const []}) {
  final jsonBytes = utf8.encode(jsonEncode(json));
  final blob = ByteData(records.length * 24);
  for (var i = 0; i < records.length; i++) {
    final r = records[i];
    blob.setInt32(i * 24, r[0].toInt(), Endian.little);
    for (var f = 0; f < 5; f++) {
      blob.setFloat32(i * 24 + 4 + f * 4, r[f + 1].toDouble(), Endian.little);
    }
  }
  final blobStart = (12 + jsonBytes.length + 7) & ~7;
  final bytes = Uint8List(blobStart + blob.lengthInBytes);
  final header = ByteData.sublistView(bytes);
  bytes.setAll(0, ascii.encode('ICRP'));
  header.setUint32(4, ReplayDocument.formatVersion, Endian.little);
  header.setUint32(8, jsonBytes.length, Endian.little);
  bytes.setAll(12, jsonBytes);
  bytes.setAll(blobStart, blob.buffer.asUint8List());
  return bytes;
}

Map<String, Object?> sampleJson({Map<String, Object?>? movement}) => {
      'decoder': {'name': 'icarus_replay', 'version': 'test'},
      'match': {
        'id': 'match',
        'mapPath': '/Game/Maps/Juliett/Juliett',
        'build': '++Ares-Core+release-13.00',
        'durationMs': 100000,
        'recordedAt': '2026-07-10T03:35:45Z',
      },
      'players': [
        {
          'subject': 'a',
          'agentId': 'ADD6443A-41BD-E414-F6AD-E58D267F4E95',
          'team': 'Red'
        },
        {
          'subject': 'b',
          'agentId': '8e253930-4c05-31dd-1b6c-968525494517',
          'team': 'Blue'
        },
      ],
      'rounds': [
        {
          'index': 0,
          'startMs': 1000,
          'combatStartMs': 31000,
          'endMs': 60000,
          'attackingTeam': 'Red',
          'winningTeam': 'Blue',
          'endReason': 'defused',
          'economy': []
        },
        {
          'index': 1,
          'startMs': 60000,
          'endMs': 100000,
          'attackingTeam': 'Red',
          'economy': [
            {'subject': 'a', 'credits': 900, 'loadoutValue': 3900, 'armor': 50},
          ]
        },
      ],
      'kills': [
        {'timeMs': 50000, 'victim': 'a', 'killer': 'b', 'assists': []},
        {'timeMs': 40000, 'victim': 'b', 'killer': 'a'},
      ],
      'vitals': {
        'a': [
          [1000, 100, 0],
          [45000, 40, 0],
          [50000, 0, 0],
          [60000, 100, 50]
        ],
      },
      'utility': [],
      'casts': [],
      'movement': movement ?? {},
      'quality': {'transformVerified': true, 'decodeErrors': 0},
    };

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
