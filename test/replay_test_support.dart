import 'dart:convert';
import 'dart:typed_data';

import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:uuid/uuid.dart';

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


/// What the library's New Strategy makes: one blank page.
Future<StrategyData> createBlankStrategy(MapValue map, String name) async {
  final strategy = StrategyData(
    id: const Uuid().v4(),
    name: name,
    mapData: map,
    versionNumber: Settings.versionNumber,
    lastEdited: DateTime.now(),
    folderID: null,
    pages: [
      StrategyPage(
        id: const Uuid().v4(),
        name: 'Page 1',
        isAutoNamed: true,
        drawingData: const [],
        agentData: const [],
        abilityData: const [],
        textData: const [],
        imageData: const [],
        utilityData: const [],
        sortIndex: 0,
        isAttack: true,
        settings: StrategySettings(),
      ),
    ],
  );
  await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
      .put(strategy.id, strategy);
  return strategy;
}
