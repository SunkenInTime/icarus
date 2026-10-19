import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/migrations/custom_circle_box_migration.dart';
import 'package:icarus/migrations/map_scale_history.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus/strategy/strategy_models.dart';

const _virtualToWorld = 1000 / 831;
const _map = MapValue.ascent;
const _world = Offset(1000 * 16 / 9, 1000);

PlacedUtility _circle(String id,
        {double? diameter = 14, bool deleted = false}) =>
    PlacedUtility(
      id: id,
      type: UtilityType.customCircle,
      position: const Offset(410, 270),
      customDiameter: diameter,
      customColorValue: 0xFF22C55E,
      customOpacityPercent: 30,
    )..isDeleted = deleted;

final _rectangle = PlacedUtility(
  id: 'rectangle',
  type: UtilityType.customRectangle,
  position: const Offset(520, 300),
  customWidth: 6,
  customLength: 18,
)..rotation = 0.6;

final _circleAgent = PlacedCircleAgent(
  id: 'brimstone',
  type: AgentType.brimstone,
  position: const Offset(340, 210),
  diameterMeters: 40,
  colorValue: 0xFFEF4444,
  opacityPercent: 20,
);

StrategyPage _page(bool attack, {List<PlacedUtility>? utilities}) =>
    StrategyPage(
      id: attack ? 'attack' : 'defense',
      name: 'Sky smoke reach',
      sortIndex: attack ? 0 : 1,
      isAutoNamed: false,
      isAttack: attack,
      settings: StrategySettings(),
      drawingData: const [],
      agentData: [_circleAgent],
      abilityData: const [],
      utilityData: utilities ??
          [
            _circle('circle'),
            _circle('deleted-circle', deleted: true),
            _circle('no-diameter', diameter: null),
            _rectangle,
          ],
      textData: const [],
      imageData: const [],
    );

StrategyData _strategy({int version = 103, List<StrategyPage>? pages}) =>
    StrategyData(
      id: 'ascent',
      name: 'Circle box',
      mapData: _map,
      versionNumber: version,
      lastEdited: DateTime.utc(2026, 10, 1),
      folderID: 'folder',
      pages: pages ?? [_page(true), _page(false)],
    );

/// Where [utility]'s circle is centred, in world units, when its position is
/// the top-left of a box [boxMeters] wide on a map at [mapScale].
Offset _centre(PlacedUtility utility, double boxMeters, double mapScale) {
  final box = CustomCircleUtility.diameterInVirtual(
    diameterMeters: boxMeters,
    mapScale: mapScale,
  );
  return utility.position + Offset(box / 2, box / 2) * _virtualToWorld;
}

void _expectPoint(Offset actual, Offset expected) {
  expect(actual.dx, closeTo(expected.dx, 1e-7));
  expect(actual.dy, closeTo(expected.dy, 1e-7));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final mapScale = Maps.mapScale[_map]!;

  test('circles go up to 110 m, Brimstone and Clove smoke reach', () {
    expect(CustomCircleUtility.maxDiameterMeters, 110);
    expect(customCircleBoxMetersBeforeVersion104, 40);
  });

  test('v103 circles keep their centre on both sides', () {
    final source = _strategy();
    final result = StrategyMigrator.migrateToCurrentVersion(source);
    expect(result.versionNumber, Settings.versionNumber);
    for (var i = 0; i < source.pages.length; i++) {
      final before = source.pages[i].utilityData;
      final after = result.pages[i].utilityData;
      for (var j = 0; j < 3; j++) {
        _expectPoint(
          _centre(after[j], CustomCircleUtility.maxDiameterMeters, mapScale),
          _centre(before[j], 40, mapScale),
        );
        expect(after[j].position, isNot(before[j].position));
        expect(after[j].toJson()..remove('position'),
            before[j].toJson()..remove('position'));
      }
      expect(after[1].isDeleted, isTrue);
      expect(after[3].toJson(), before[3].toJson());
      expect(
        result.pages[i].agentData.single.toJson(),
        source.pages[i].agentData.single.toJson(),
      );
    }
  });

  test('the top-left moves out by half the growth, 35 m', () {
    final result = StrategyMigrator.migrateToCurrentVersion(_strategy());
    final before = _strategy().pages.first.utilityData.first;
    final after = result.pages.first.utilityData.first;
    const meters = 35 * AgentData.inGameMetersDiameter;
    final shift = meters * mapScale * _virtualToWorld;
    _expectPoint(before.position - after.position, Offset(shift, shift));
  });

  test('a migrated strategy is never moved again', () {
    final once = StrategyMigrator.migrateToCurrentVersion(_strategy());
    expect(
      identical(StrategyMigrator.migrateToCurrentVersion(once), once),
      isTrue,
    );
    final current = _strategy(version: CustomCircleBoxMigration.version);
    expect(
      identical(StrategyMigrator.migrateToCurrentVersion(current), current),
      isTrue,
    );
  });

  test('strategies without a custom circle keep their pages and edit time', () {
    final source = _strategy(pages: [
      _page(true, utilities: [_rectangle]),
    ]);
    final result = StrategyMigrator.migrateToCurrentVersion(source);
    expect(identical(result.pages, source.pages), isTrue);
    expect(result.lastEdited, source.lastEdited);
    expect(result.versionNumber, Settings.versionNumber);
  });

  test('a v96 defense circle is mirrored in the box it was placed in', () {
    // Canonical coordinates (97) reflect a defense circle about its centre.
    // Measured in the live 110 m box, that centre would be off by 35 m.
    final source = _strategy(version: 96, pages: [
      _page(false, utilities: [_circle('circle')]),
    ]);
    final result = StrategyMigrator.migrateToCurrentVersion(source);
    final before = source.pages.single.utilityData.single;
    final after = result.pages.single.utilityData.single;
    final oldCentre = _centre(before, 40, mapScaleBeforeVersion98(_map));
    _expectPoint(
      _centre(after, CustomCircleUtility.maxDiameterMeters, mapScale),
      _world - oldCentre,
    );
  });

  test('zip export/import does not move circles a second time', () async {
    final migrated = await StrategyMigrator.migrateLegacyData(_strategy());
    final exportedPages =
        migrated.pages.map((p) => p.toJson(migrated.id)).toList();
    final bytes = utf8.encode(
      jsonEncode({
        'versionNumber': '${migrated.versionNumber}',
        'pages': exportedPages,
      }),
    );
    final archive = Archive()
      ..addFile(ArchiveFile('strategy.json', bytes.length, bytes));
    final decoded = jsonDecode(
      utf8.decode(
        ZipDecoder()
            .decodeBytes(ZipEncoder().encode(archive))
            .files
            .single
            .content as List<int>,
      ),
    ) as Map<String, dynamic>;
    final pages = await StrategyPage.listFromJson(
      json: jsonEncode(decoded['pages']),
      strategyID: migrated.id,
      isZip: true,
    );
    final restored = await StrategyMigrator.migrateLegacyData(
      migrated.copyWith(
        versionNumber: int.parse(decoded['versionNumber'] as String),
        pages: pages,
      ),
    );
    expect(
      restored.pages.map((p) => p.toJson(restored.id)).toList(),
      exportedPages,
    );
  });
}
