import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:path/path.dart' as path;

class _IcaFixture {
  const _IcaFixture({
    required this.name,
    required this.file,
    required this.decodedJson,
  });

  final String name;
  final File file;
  final Map<String, dynamic> decodedJson;
}

String get _fixtureDirectory =>
    path.join(Directory.current.path, 'test', 'fixtures', 'strategy_integrity');

Future<List<_IcaFixture>> _loadFixtureMatrix() async {
  final root = Directory(_fixtureDirectory);
  if (!root.existsSync()) {
    return [];
  }

  final candidates = root
      .listSync()
      .whereType<File>()
      .where((file) => path.extension(file.path).toLowerCase() == '.ica')
      .toList(growable: false)
    ..sort((a, b) => a.path.compareTo(b.path));

  final fixtures = <_IcaFixture>[];
  for (final file in candidates) {
    fixtures.add(
      _IcaFixture(
        name: path.basename(file.path),
        file: file,
        decodedJson: await _readIcaJson(file),
      ),
    );
  }

  return fixtures;
}

Future<Map<String, dynamic>> _readIcaJson(File file) async {
  final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
  ArchiveFile? jsonEntry;

  for (final entry in archive) {
    if (entry.isFile && path.extension(entry.name).toLowerCase() == '.json') {
      jsonEntry = entry;
      break;
    }
  }

  if (jsonEntry == null) {
    throw const FormatException('No JSON payload found in .ica archive');
  }

  final raw = utf8.decode(jsonEntry.content as List<int>);
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('ICA JSON payload must decode to an object');
  }

  return decoded;
}

Map<String, dynamic> _buildExportPayload(StrategyData strategy) {
  return {
    'versionNumber': '${Settings.versionNumber}',
    'mapData': Maps.mapNames[strategy.mapData],
    'themePalette': strategy.themeOverridePalette?.toJson(),
    'pages': strategy.pages.map((page) => page.toJson(strategy.id)).toList(),
  };
}

Future<StrategyData> _importStrategyFromDecoded({
  required Map<String, dynamic> decoded,
  required String strategyName,
  required String strategyId,
  required bool isZip,
}) async {
  final drawingData =
      DrawingProvider.fromJson(jsonEncode(decoded['drawingData'] ?? []));
  final agentData =
      AgentProvider.fromJson(jsonEncode(decoded['agentData'] ?? []));
  final abilityData =
      AbilityProvider.fromJson(jsonEncode(decoded['abilityData'] ?? []));
  final textData = TextProvider.fromJson(jsonEncode(decoded['textData'] ?? []));
  final utilityData =
      UtilityProvider.fromJson(jsonEncode(decoded['utilityData'] ?? []));

  final settingsData = decoded['settingsData'] is Map
      ? StrategySettings.fromJson(
          Map<String, dynamic>.from(decoded['settingsData'] as Map),
        )
      : StrategySettings();

  final isAttack = decoded['isAttack'] == null
      ? true
      : decoded['isAttack'].toString().toLowerCase() == 'true';

  final pages = decoded['pages'] != null
      ? await StrategyPage.listFromJson(
          json: jsonEncode(decoded['pages']),
          strategyID: strategyId,
          isZip: isZip,
        )
      : <StrategyPage>[];

  final mapData = MapProvider.fromJson(jsonEncode(decoded['mapData']));
  final versionNumber =
      int.tryParse(decoded['versionNumber']?.toString() ?? '') ??
          Settings.versionNumber;

  StrategyData strategy = StrategyData(
    // ignore: deprecated_member_use, deprecated_member_use_from_same_package
    drawingData: drawingData,
    // ignore: deprecated_member_use, deprecated_member_use_from_same_package
    agentData: agentData,
    // ignore: deprecated_member_use, deprecated_member_use_from_same_package
    abilityData: abilityData,
    // ignore: deprecated_member_use, deprecated_member_use_from_same_package
    textData: textData,
    // ignore: deprecated_member_use, deprecated_member_use_from_same_package
    imageData: const <PlacedImage>[],
    // ignore: deprecated_member_use, deprecated_member_use_from_same_package
    utilityData: utilityData,
    // ignore: deprecated_member_use, deprecated_member_use_from_same_package
    isAttack: isAttack,
    // ignore: deprecated_member_use, deprecated_member_use_from_same_package
    strategySettings: settingsData,
    id: strategyId,
    name: strategyName,
    mapData: mapData,
    versionNumber: versionNumber,
    lastEdited: DateTime.utc(2026, 1, 1),
    folderID: null,
    pages: pages,
  );

  strategy = await StrategyProvider.migrateLegacyData(strategy);
  return strategy;
}

void _expectCustomShapes(StrategyData strategy, String fixtureName) {
  final utilities = [
    for (final page in strategy.pages) ...page.utilityData,
  ];

  final circle = utilities.firstWhere(
    (utility) => utility.type == UtilityType.customCircle,
    orElse: () =>
        throw StateError('Missing custom circle in fixture $fixtureName'),
  );
  final rectangle = utilities.firstWhere(
    (utility) => utility.type == UtilityType.customRectangle,
    orElse: () =>
        throw StateError('Missing custom rectangle in fixture $fixtureName'),
  );

  expect(circle.customDiameter, 14.0, reason: fixtureName);
  expect(circle.customColorValue, 0xFF3B82F6, reason: fixtureName);
  expect(circle.customOpacityPercent, 35, reason: fixtureName);

  expect(rectangle.customWidth, 6.0, reason: fixtureName);
  expect(rectangle.customLength, 18.0, reason: fixtureName);
  expect(rectangle.customColorValue, 0xFF22C55E, reason: fixtureName);
  expect(rectangle.customOpacityPercent, 30, reason: fixtureName);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Strategy fixture matrix', () {
    test('loads historical fixtures including base-test.ica', () async {
      final fixtures = await _loadFixtureMatrix();

      expect(fixtures, isNotEmpty);
      expect(fixtures.map((f) => f.name), contains('base-test.ica'));
      expect(fixtures.map((f) => f.name), contains('base-test-v43.ica'));

      for (final fixture in fixtures) {
        expect(
          fixture.decodedJson,
          containsPair('mapData', isA<Object>()),
          reason: 'Fixture ${fixture.name} is missing required mapData',
        );

        expect(
          jsonEncode(fixture.decodedJson),
          contains('customCircle'),
          reason: 'Fixture ${fixture.name} must include a custom circle',
        );
        expect(
          jsonEncode(fixture.decodedJson),
          contains('customRectangle'),
          reason: 'Fixture ${fixture.name} must include a custom rectangle',
        );
      }
    });

    test('legacy fixture import migrates to current schema', () async {
      final fixtures = await _loadFixtureMatrix();

      for (final fixture in fixtures) {
        final imported = await _importStrategyFromDecoded(
          decoded: fixture.decodedJson,
          strategyName: path.basenameWithoutExtension(fixture.name),
          strategyId: 'legacy-${fixture.name}',
          isZip: true,
        );

        expect(imported.pages, isNotEmpty, reason: fixture.name);
        expect(
          imported.versionNumber,
          lessThanOrEqualTo(Settings.versionNumber),
          reason: fixture.name,
        );
        _expectCustomShapes(imported, fixture.name);

        final payload = _buildExportPayload(imported);
        expect(payload['pages'], isA<List<dynamic>>(), reason: fixture.name);
      }
    });
  });

  group('Strategy round-trip integrity', () {
    test('current schema export -> import preserves canonical structure',
        () async {
      final currentPayload = <String, dynamic>{
        'versionNumber': '${Settings.versionNumber}',
        'mapData': 'ascent',
        'pages': [
          {
            'id': 'page-1',
            'sortIndex': '0',
            'name': 'Page 1',
            'drawingData': <dynamic>[],
            'agentData': [
              {
                'id': 'agent-1',
                'isDeleted': false,
                'position': {'dx': 10.0, 'dy': 20.0},
                'type': 'jett',
                'isAlly': true,
                'state': 'none',
                'lineUpID': null,
              },
            ],
            'abilityData': [
              {
                'id': 'ability-1',
                'isDeleted': false,
                'position': {'dx': 100.0, 'dy': 200.0},
                'data': {'type': 'jett', 'index': 0},
                'isAlly': true,
                'rotation': 0.0,
                'length': 0.0,
                'lineUpID': null,
              },
            ],
            'textData': [
              {
                'id': 'text-1',
                'isDeleted': false,
                'position': {'dx': 300.0, 'dy': 400.0},
                'text': 'entry',
                'size': 120.0,
                'tagColorValue': null,
              },
            ],
            'imageData': [
              {
                'id': 'img-1',
                'isDeleted': false,
                'position': {'dx': 500.0, 'dy': 600.0},
                'aspectRatio': 1.0,
                'fileExtension': '.png',
                'scale': 220.0,
                'tagColorValue': null,
                'link': '',
              },
            ],
            'utilityData': [
              {
                'id': 'utility-circle',
                'isDeleted': false,
                'position': {'dx': 700.0, 'dy': 800.0},
                'type': 'customCircle',
                'rotation': 0.0,
                'length': 0.0,
                'angle': 0.0,
                'attachedAgentId': null,
                'customDiameter': 14.0,
                'customWidth': null,
                'customLength': null,
                'customColorValue': 0xFF3B82F6,
                'customOpacityPercent': 35,
              },
              {
                'id': 'utility-rectangle',
                'isDeleted': false,
                'position': {'dx': 780.0, 'dy': 820.0},
                'type': 'customRectangle',
                'rotation': 0.0,
                'length': 0.0,
                'angle': 0.0,
                'attachedAgentId': null,
                'customDiameter': null,
                'customWidth': 6.0,
                'customLength': 18.0,
                'customColorValue': 0xFF22C55E,
                'customOpacityPercent': 30,
              },
            ],
            'isAttack': 'true',
            'settings': {'agentSize': 35.0, 'abilitySize': 25.0},
            'lineUpData': <dynamic>[],
          },
        ],
      };

      final imported = await _importStrategyFromDecoded(
        decoded: currentPayload,
        strategyName: 'CurrentTest',
        strategyId: 'current-test',
        isZip: true,
      );

      final exported = _buildExportPayload(imported);
      final reImported = await _importStrategyFromDecoded(
        decoded: exported,
        strategyName: 'CurrentTestAgain',
        strategyId: 'current-test-2',
        isZip: true,
      );
      final reExported = _buildExportPayload(reImported);

      _expectCustomShapes(
        reImported,
        'current schema export -> import preserves custom shapes',
      );
      expect(reExported, equals(exported));
    });

    test('legacy import -> current export -> re-import remains consistent',
        () async {
      final fixture = File(path.join(_fixtureDirectory, 'base-test.ica'));
      final decoded = await _readIcaJson(fixture);

      final importedLegacy = await _importStrategyFromDecoded(
        decoded: decoded,
        strategyName: 'legacy-base-test',
        strategyId: 'legacy-base-test',
        isZip: true,
      );

      final exportedCurrent = _buildExportPayload(importedLegacy);

      final reImported = await _importStrategyFromDecoded(
        decoded: exportedCurrent,
        strategyName: 'legacy-base-test-reimport',
        strategyId: 'legacy-base-test-reimport',
        isZip: true,
      );

      final reExportedCurrent = _buildExportPayload(reImported);

      expect(reImported.versionNumber, Settings.versionNumber);
      _expectCustomShapes(reImported, 'base-test.ica');
      expect(reExportedCurrent, equals(exportedCurrent));
    });

    test('previous-version custom-shape fixture imports and re-exports cleanly',
        () async {
      final fixture = File(path.join(_fixtureDirectory, 'base-test-v43.ica'));
      final decoded = await _readIcaJson(fixture);

      final imported = await _importStrategyFromDecoded(
        decoded: decoded,
        strategyName: 'legacy-v43',
        strategyId: 'legacy-v43',
        isZip: true,
      );

      final exported = _buildExportPayload(imported);

      final reImported = await _importStrategyFromDecoded(
        decoded: exported,
        strategyName: 'legacy-v43-reimport',
        strategyId: 'legacy-v43-reimport',
        isZip: true,
      );

      final reExported = _buildExportPayload(reImported);

      expect(imported.versionNumber, Settings.versionNumber - 1);
      _expectCustomShapes(imported, 'base-test-v43.ica');
      expect(reExported, equals(exported));
    });

    test('custom shape utility dimensions support undo and redo', () {
      final rectangle = PlacedUtility(
        id: 'rectangle-undo',
        type: UtilityType.customRectangle,
        position: const Offset(10, 10),
        customWidth: 6.0,
        customLength: 18.0,
      );
      rectangle.updateCustomShapeSize(newWidth: 9.0, newLength: 22.0);

      rectangle.undoAction();
      expect(rectangle.customWidth, 6.0);
      expect(rectangle.customLength, 18.0);

      rectangle.redoAction();
      expect(rectangle.customWidth, 9.0);
      expect(rectangle.customLength, 22.0);

      final circle = PlacedUtility(
        id: 'circle-undo',
        type: UtilityType.customCircle,
        position: const Offset(20, 20),
        customDiameter: 10.0,
      );
      circle.updateCustomShapeSize(newDiameter: 14.0);

      circle.undoAction();
      expect(circle.customDiameter, 10.0);

      circle.redoAction();
      expect(circle.customDiameter, 14.0);
    });

    test('imported custom shapes retain dimensions and styling fields', () async {
      final fixture = File(path.join(_fixtureDirectory, 'base-test.ica'));
      final decoded = await _readIcaJson(fixture);

      final imported = await _importStrategyFromDecoded(
        decoded: decoded,
        strategyName: 'custom-shape-assertions',
        strategyId: 'custom-shape-assertions',
        isZip: true,
      );

      _expectCustomShapes(imported, 'base-test.ica');
    });

    test('derived fields are recomputed on import', () async {
      final payload = <String, dynamic>{
        'versionNumber': '${Settings.versionNumber}',
        'mapData': 'ascent',
        'pages': [
          {
            'id': 'p-1',
            'sortIndex': '42',
            'name': 'Misindexed',
            'drawingData': <DrawingElement>[],
            'agentData': <PlacedAgent>[],
            'abilityData': <PlacedAbility>[],
            'textData': <PlacedText>[],
            'imageData': [
              {
                'id': 'img-oversized',
                'isDeleted': false,
                'position': {'dx': 1.0, 'dy': 2.0},
                'aspectRatio': 1.0,
                'fileExtension': '.png',
                'scale': 9999.0,
                'link': '',
              },
            ],
            'utilityData': <PlacedUtility>[],
            'isAttack': 'true',
            'settings': {'agentSize': 35.0, 'abilitySize': 25.0},
            'lineUpData': <LineUp>[],
          },
        ],
      };

      final imported = await _importStrategyFromDecoded(
        decoded: payload,
        strategyName: 'DerivedFieldTest',
        strategyId: 'derived-field-test',
        isZip: true,
      );

      expect(imported.pages.single.sortIndex, 0);
      expect(imported.pages.single.imageData.single.scale, 500.0);
      expect(imported.createdAt, imported.lastEdited);
    });
  });

  group('Negative integrity handling', () {
    test('missing required mapData fails deterministically', () async {
      final payload = <String, dynamic>{
        'versionNumber': '${Settings.versionNumber}',
        'pages': <dynamic>[],
      };

      expect(
        () => _importStrategyFromDecoded(
          decoded: payload,
          strategyName: 'MissingMapData',
          strategyId: 'missing-mapdata',
          isZip: true,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('corrupt pages shape fails deterministically', () async {
      final payload = <String, dynamic>{
        'versionNumber': '${Settings.versionNumber}',
        'mapData': 'ascent',
        'pages': 'not-a-list',
      };

      expect(
        () => _importStrategyFromDecoded(
          decoded: payload,
          strategyName: 'CorruptPages',
          strategyId: 'corrupt-pages',
          isZip: true,
        ),
        throwsA(anyOf(isA<TypeError>(), isA<FormatException>())),
      );
    });

    test('archive without json payload fails deterministically', () async {
      final tmpDir = await Directory.systemTemp.createTemp('icarus-integrity');
      final badFixture = File(path.join(tmpDir.path, 'no-json.ica'));

      final archive = Archive();
      archive.addFile(ArchiveFile('only.txt', 3, utf8.encode('bad')));
      await badFixture.writeAsBytes(ZipEncoder().encode(archive));

      expect(
        () => _readIcaJson(badFixture),
        throwsA(isA<FormatException>()),
      );

      await tmpDir.delete(recursive: true);
    });
  });
}
