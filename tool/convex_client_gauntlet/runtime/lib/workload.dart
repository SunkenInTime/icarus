import 'dart:convert';

import 'package:crypto/crypto.dart';

const operationsPerSeed = 1000;
const operationBatchSize = 50;
const cloudProtocolVersion = 3;
const payloadVersion = 1;
const baseFixturePath = 'test/fixtures/strategy_integrity/base-test-v43.ica';
const baseFixtureSha256 =
    '8544873d608a0ad885b2e6042a383596a0b1dc37514034281b4e4eec6168756a';

enum _ContentEntity { element, lineup }

String seedPrefix(int seed) => 'seed-$seed-';
String strategyId(int seed) => '${seedPrefix(seed)}strategy';
String folderId(int seed) => '${seedPrefix(seed)}folder';
String initialPageId(int seed) => '${seedPrefix(seed)}page-custom-shapes';
String secondaryPageId(int seed) => '${seedPrefix(seed)}page-secondary';

List<Map<String, Object?>> buildOperationTrace(int seed) {
  final operations = <Map<String, Object?>>[];
  var sequence = 0;

  void add(Map<String, Object?> operation) {
    operations.add(<String, Object?>{
      'opId': '${seedPrefix(seed)}op-${sequence.toString().padLeft(4, '0')}',
      ...operation,
    });
    sequence += 1;
  }

  for (var cycle = 0; cycle < 80; cycle += 1) {
    _addRevisionCycle(
      add: add,
      entity: _ContentEntity.element,
      publicId:
          '${seedPrefix(seed)}element-${cycle.toString().padLeft(3, '0')}',
      pagePublicId: initialPageId(seed),
      payloadBuilder: (variant) => _utilityPayload(seed, cycle, variant),
      initialSortIndex: 100 + cycle,
      finalSortIndex: 8000 + cycle,
    );
  }

  for (var cycle = 0; cycle < 10; cycle += 1) {
    _addRevisionCycle(
      add: add,
      entity: _ContentEntity.lineup,
      publicId: '${seedPrefix(seed)}lineup-${cycle.toString().padLeft(3, '0')}',
      pagePublicId: initialPageId(seed),
      payloadBuilder: (variant) => _lineupPayload(seed, cycle, variant),
      initialSortIndex: 1000 + cycle,
      finalSortIndex: 9000 + cycle,
    );
  }

  final secondPage = secondaryPageId(seed);
  add({
    'type': 'page.add',
    'pagePublicId': secondPage,
    'payload': {'name': 'Secondary', 'isAttack': false},
    'sortIndex': 1,
    'expectedStrategyRevision': 0,
  });
  add({
    'type': 'page.patch',
    'pagePublicId': secondPage,
    'payload': {'name': 'Secondary A'},
    'expectedPageRevision': 1,
  });
  add({
    'type': 'page.reorder',
    'pagePublicId': secondPage,
    'sortIndex': 0,
    'expectedStrategyRevision': 1,
  });
  add({
    'type': 'page.patch',
    'pagePublicId': secondPage,
    'payload': {'name': 'Secondary B'},
    'expectedPageRevision': 3,
  });
  add({
    'type': 'page.delete',
    'pagePublicId': secondPage,
    'expectedStrategyRevision': 2,
  });
  add({
    'type': 'page.delete',
    'pagePublicId': secondPage,
    'expectedStrategyRevision': 2,
  });
  add({
    'type': 'page.add',
    'pagePublicId': secondPage,
    'payload': {'name': 'Secondary C', 'isAttack': false},
    'sortIndex': 1,
    'expectedStrategyRevision': 3,
  });
  add({
    'type': 'page.patch',
    'pagePublicId': secondPage,
    'payload': {'name': 'Secondary D'},
    'expectedPageRevision': 1,
  });
  add({
    'type': 'page.reorder',
    'pagePublicId': secondPage,
    'sortIndex': 0,
    'expectedStrategyRevision': 4,
  });
  add({
    'type': 'page.patch',
    'pagePublicId': secondPage,
    'payload': {'name': 'Secondary final'},
    'expectedPageRevision': 3,
  });

  for (var index = 0; index < 10; index += 1) {
    add({
      'type': 'strategy.patch',
      'payload': {'name': 'Gauntlet seed $seed revision $index'},
      'expectedStrategyRevision': 5 + index,
    });
  }

  for (var index = 0; index < 80; index += 1) {
    add({
      'type': 'pageContent.patch',
      'pagePublicId': initialPageId(seed),
      'settings': {
        'agentSize': 36 + (index % 5),
        'abilitySize': 26 + (index % 3),
        'useNeutralTeamColors': index.isEven,
      },
      'expectedPageContentRevision': 1 + index,
    });
  }

  if (operations.length != operationsPerSeed) {
    throw StateError(
      'Trace contains ${operations.length} operations, expected '
      '$operationsPerSeed',
    );
  }
  return List.unmodifiable(operations);
}

void _addRevisionCycle({
  required void Function(Map<String, Object?>) add,
  required _ContentEntity entity,
  required String publicId,
  required String pagePublicId,
  required Map<String, Object?> Function(int variant) payloadBuilder,
  required int initialSortIndex,
  required int finalSortIndex,
}) {
  final publicIdKey = switch (entity) {
    _ContentEntity.element => 'elementPublicId',
    _ContentEntity.lineup => 'lineupPublicId',
  };
  final revisionKey = switch (entity) {
    _ContentEntity.element => 'expectedElementRevision',
    _ContentEntity.lineup => 'expectedLineupRevision',
  };
  final typePrefix = entity.name;
  add({
    'type': '$typePrefix.add',
    publicIdKey: publicId,
    'pagePublicId': pagePublicId,
    'payload': payloadBuilder(0),
    'sortIndex': initialSortIndex,
  });
  add({
    'type': '$typePrefix.patch',
    publicIdKey: publicId,
    'payload': payloadBuilder(1),
    revisionKey: 1,
  });
  add({
    'type': '$typePrefix.patch',
    publicIdKey: publicId,
    'payload': payloadBuilder(2),
    revisionKey: 1,
  });
  add({
    'type': '$typePrefix.patch',
    publicIdKey: publicId,
    'payload': payloadBuilder(3),
    revisionKey: 2,
  });
  add({
    'type': '$typePrefix.reorder',
    publicIdKey: publicId,
    'pagePublicId': pagePublicId,
    'sortIndex': finalSortIndex - 1,
    revisionKey: 3,
  });
  add({
    'type': '$typePrefix.delete',
    publicIdKey: publicId,
    'pagePublicId': pagePublicId,
    revisionKey: 4,
  });
  add({
    'type': '$typePrefix.add',
    publicIdKey: publicId,
    'pagePublicId': pagePublicId,
    'payload': payloadBuilder(4),
    'sortIndex': finalSortIndex - 2,
    revisionKey: 5,
  });
  add({
    'type': '$typePrefix.patch',
    publicIdKey: publicId,
    'payload': payloadBuilder(5),
    revisionKey: 6,
  });
  add({
    'type': '$typePrefix.reorder',
    publicIdKey: publicId,
    'pagePublicId': pagePublicId,
    'sortIndex': finalSortIndex,
    revisionKey: 7,
  });
  add({
    'type': '$typePrefix.patch',
    publicIdKey: publicId,
    'payload': payloadBuilder(6),
    revisionKey: 8,
  });
}

Map<String, Object?> _utilityPayload(int seed, int cycle, int variant) {
  final id = '${seedPrefix(seed)}element-${cycle.toString().padLeft(3, '0')}';
  return {
    'kind': 'utility',
    'payloadVersion': payloadVersion,
    'data': {
      'id': id,
      'isDeleted': false,
      'position': {
        'dx': 100 + cycle.toDouble(),
        'dy': 150 + variant.toDouble(),
      },
      'type': 'customCircle',
      'rotation': 0,
      'length': 0,
      'angle': 0,
      'attachedAgentId': null,
      'customDiameter': 10 + variant.toDouble(),
      'customWidth': null,
      'customLength': null,
      'customColorValue': 4282090230,
      'customOpacityPercent': 30 + variant,
    },
  };
}

Map<String, Object?> _lineupPayload(int seed, int cycle, int variant) {
  final id = '${seedPrefix(seed)}lineup-${cycle.toString().padLeft(3, '0')}';
  return {
    'kind': 'lineupGroup',
    'payloadVersion': payloadVersion,
    'data': {
      'id': id,
      'agent': {
        'id': '$id-agent',
        'isDeleted': false,
        'position': {'dx': 10 + cycle, 'dy': 20 + variant},
        'type': 'sova',
        'isAlly': true,
        'state': 'none',
        'kind': 'plain',
        'lineUpID': id,
      },
      'items': [
        {
          'id': '$id-item',
          'ability': {
            'id': '$id-ability',
            'isDeleted': false,
            'data': {'type': 'sova', 'index': 2},
            'position': {'dx': 30 + cycle, 'dy': 40 + variant},
            'isAlly': true,
            'rotation': 0,
            'length': 0,
            'lineUpID': id,
            'visualState': {
              'showRangeOutline': true,
              'showRangeFill': true,
              'showInnerOutline': true,
              'showInnerFill': true,
            },
            'armLengthsMeters': [10, 10, 10, 10],
          },
          'youtubeLink': '',
          'notes': 'seed $seed cycle $cycle variant $variant',
          'images': <Object?>[],
        },
      ],
    },
  };
}

List<Map<String, Object?>> baseElementOps(int seed) {
  Map<String, Object?> basePayload({
    required String id,
    required Map<String, Object?> position,
    required String type,
    required double? diameter,
    required double? width,
    required double? length,
    required int color,
    required int opacity,
  }) => {
    'kind': 'utility',
    'payloadVersion': payloadVersion,
    'data': {
      'id': id,
      'isDeleted': false,
      'position': position,
      'type': type,
      'rotation': 0,
      'length': 0,
      'angle': 0,
      'attachedAgentId': null,
      'customDiameter': diameter,
      'customWidth': width,
      'customLength': length,
      'customColorValue': color,
      'customOpacityPercent': opacity,
    },
  };

  return [
    {
      'opId': '${seedPrefix(seed)}base-circle',
      'type': 'element.add',
      'elementPublicId': '${seedPrefix(seed)}utility-circle-current',
      'pagePublicId': initialPageId(seed),
      'sortIndex': 0,
      'payload': basePayload(
        id: '${seedPrefix(seed)}utility-circle-current',
        position: {'dx': 220.0, 'dy': 180.0},
        type: 'customCircle',
        diameter: 14.0,
        width: null,
        length: null,
        color: 4282090230,
        opacity: 35,
      ),
    },
    {
      'opId': '${seedPrefix(seed)}base-rectangle',
      'type': 'element.add',
      'elementPublicId': '${seedPrefix(seed)}utility-rectangle-current',
      'pagePublicId': initialPageId(seed),
      'sortIndex': 1,
      'payload': basePayload(
        id: '${seedPrefix(seed)}utility-rectangle-current',
        position: {'dx': 420.0, 'dy': 280.0},
        type: 'customRectangle',
        diameter: null,
        width: 6.0,
        length: 18.0,
        color: 4280468830,
        opacity: 30,
      ),
    },
  ];
}

String canonicalJson(Object? value) => jsonEncode(_sortJson(value));

String canonicalHash(Object? value) =>
    sha256.convert(utf8.encode(canonicalJson(value))).toString();

Object? canonicalSnapshot({
  required int seed,
  required Object? snapshot,
  required Object? folders,
}) {
  final normalizedSnapshot = _stripTransportMetadata(snapshot);
  final folderList = (folders as List<dynamic>)
      .whereType<Map<dynamic, dynamic>>()
      .where((folder) => folder['publicId'] == folderId(seed))
      .map(_stripTransportMetadata)
      .toList(growable: false);
  return _replaceSeedPrefix({
    'snapshot': normalizedSnapshot,
    'folders': folderList,
  }, seedPrefix(seed));
}

Object? _stripTransportMetadata(Object? value) {
  if (value is List<dynamic>) {
    return value.map(_stripTransportMetadata).toList(growable: false);
  }
  if (value is Map<dynamic, dynamic>) {
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key as String;
      if (key == 'createdAt' ||
          key == 'updatedAt' ||
          key == 'contentCreatedAt' ||
          key == 'contentUpdatedAt' ||
          key == 'role') {
        continue;
      }
      result[key] = _stripTransportMetadata(entry.value);
    }
    return result;
  }
  return value;
}

Object? _replaceSeedPrefix(Object? value, String prefix) {
  if (value is String) return value.replaceAll(prefix, '');
  if (value is List<dynamic>) {
    return value
        .map((item) => _replaceSeedPrefix(item, prefix))
        .toList(growable: false);
  }
  if (value is Map<dynamic, dynamic>) {
    return value.map(
      (key, item) => MapEntry(key as String, _replaceSeedPrefix(item, prefix)),
    );
  }
  return value;
}

Map<String, Object?> exportIcaRoundTrip(Object? snapshotValue) {
  final snapshot = (snapshotValue as Map<dynamic, dynamic>)
      .cast<String, dynamic>();
  final header = (snapshot['header'] as Map<dynamic, dynamic>)
      .cast<String, dynamic>();
  final pages = (snapshot['pages'] as List<dynamic>)
      .map((item) => (item as Map<dynamic, dynamic>).cast<String, dynamic>())
      .toList(growable: false);
  final elements = (snapshot['elements'] as List<dynamic>)
      .map((item) => (item as Map<dynamic, dynamic>).cast<String, dynamic>())
      .toList(growable: false);
  final lineups = (snapshot['lineups'] as List<dynamic>)
      .map((item) => (item as Map<dynamic, dynamic>).cast<String, dynamic>())
      .toList(growable: false);

  List<Object?> dataFor(String pageId, String kind) => elements
      .where(
        (element) =>
            element['pagePublicId'] == pageId &&
            element['elementType'] == kind &&
            element['deleted'] == false,
      )
      .map(
        (element) =>
            ((element['payload'] as Map<dynamic, dynamic>)['data']) as Object?,
      )
      .toList(growable: false);

  final archive = <String, Object?>{
    'versionNumber': '43',
    'mapData': header['mapData'],
    'themePalette': header['themeOverridePalette'],
    'pages': pages
        .map((page) {
          final pageId = page['publicId'] as String;
          return <String, Object?>{
            'id': pageId,
            'sortIndex': (page['sortIndex'] as num).toInt().toString(),
            'name': page['name'],
            'drawingData': dataFor(pageId, 'drawing'),
            'agentData': dataFor(pageId, 'agent'),
            'abilityData': dataFor(pageId, 'ability'),
            'textData': dataFor(pageId, 'text'),
            'imageData': dataFor(pageId, 'image'),
            'utilityData': dataFor(pageId, 'utility'),
            'isAttack': (page['isAttack'] as bool).toString(),
            'settings': page['settings'],
            'lineUpData': lineups
                .where(
                  (lineup) =>
                      lineup['pagePublicId'] == pageId &&
                      lineup['deleted'] == false,
                )
                .map(
                  (lineup) =>
                      ((lineup['payload'] as Map<dynamic, dynamic>)['data'])
                          as Object?,
                )
                .toList(growable: false),
          };
        })
        .toList(growable: false),
  };

  final encoded = canonicalJson(archive);
  final decoded = jsonDecode(encoded) as Map<String, dynamic>;
  if (canonicalJson(decoded) != encoded) {
    throw StateError('Canonical .ica JSON did not survive a JSON round-trip');
  }
  return archive;
}

Object? _sortJson(Object? value) {
  if (value is List<dynamic>) {
    return value.map(_sortJson).toList(growable: false);
  }
  if (value is Map<dynamic, dynamic>) {
    final keys = value.keys.cast<String>().toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _sortJson(value[key]),
    };
  }
  return value;
}
