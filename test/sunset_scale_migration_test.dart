import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/migrations/ability_scale_migration.dart';
import 'package:icarus/migrations/custom_circle_wrapper_migration.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

const _oldScale = 0.9502102049421427;
const _newScale = 1.06;
const _virtualToWorld = 1000 / 831;

Offset _abilityAnchor(PlacedAbility ability, double scale) =>
    ability.data.abilityData!.getAnchorPoint(
      mapScale: scale,
      abilitySize: Settings.abilitySize,
    ) *
    _virtualToWorld;

Offset _utilityAnchor(PlacedUtility utility, double scale) =>
    UtilityData.utilityWidgets[utility.type]!.getAnchorPoint(
      id: utility.id,
      mapScale: scale,
      agentSize: Settings.agentSize,
      abilitySize: Settings.abilitySize,
      length: utility.length,
      rotation: utility.rotation,
      diameterMeters: utility.customDiameter,
      widthMeters: utility.customWidth,
      rectLengthMeters: utility.customLength,
    ) *
    _virtualToWorld;

void _expectPoint(Offset actual, Offset expected) {
  expect(actual.dx, closeTo(expected.dx, 1e-7));
  expect(actual.dy, closeTo(expected.dy, 1e-7));
}

StrategyPage _page(bool attack) {
  final abilities = [
    for (final agent in AgentData.agents.values)
      for (final info in agent.abilities)
        if (info.abilityData != null)
          PlacedAbility(
            id: '${info.type.name}-${info.index}',
            data: info,
            position: const Offset(610, 340),
            rotation: 0.7,
            length: 80,
            isAlly: false,
          ),
  ];
  abilities.last.isDeleted = true;
  return StrategyPage(
    id: attack ? 'attack' : 'defense',
    name: 'Saved setup',
    sortIndex: attack ? 0 : 1,
    isAutoNamed: false,
    isAttack: attack,
    settings: StrategySettings(),
    drawingData: const [],
    agentData: [
      PlacedAgent(
        id: 'agent',
        type: AgentType.veto,
        position: const Offset(340, 210),
      ),
    ],
    abilityData: abilities,
    utilityData: [
      for (final type in UtilityType.values)
        PlacedUtility(
          id: type.name,
          type: type,
          position: const Offset(410, 270),
          customDiameter: 14,
          customWidth: 6,
          customLength: 18,
        )
          ..rotation = 0.6
          ..length = 80
          ..isDeleted = type == UtilityType.customRectangle,
    ],
    textData: const [],
    imageData: const [],
    lineUpGroups: [
      LineUpGroup(
        id: 'group',
        agent: PlacedAgent(
          id: 'lineup-agent',
          type: AgentType.veto,
          position: const Offset(340, 210),
        ),
        items: [
          LineUpItem(
            id: 'item',
            ability: abilities.first,
            notes: 'Keep this note',
            youtubeLink: 'https://example.com/reference',
            images: [SimpleImageData(id: 'reference', fileExtension: '.png')],
          ),
        ],
      ),
    ],
  );
}

StrategyData _strategy({
  int version = 97,
  MapValue map = MapValue.sunset,
  List<StrategyPage>? pages,
}) =>
    StrategyData(
      id: 'sunset',
      name: 'Range regression',
      mapData: map,
      versionNumber: version,
      lastEdited: DateTime.utc(2026, 1, 1),
      folderID: 'folder',
      pages: pages ?? [_page(true), _page(false)],
    );

void _expectAnchors(StrategyPage before, StrategyPage after) {
  expect(after.id, before.id);
  expect(after.name, before.name);
  expect(after.isAutoNamed, before.isAutoNamed);
  expect(after.isAttack, before.isAttack);
  expect(after.sortIndex, before.sortIndex);
  expect(after.agentData.single.toJson(), before.agentData.single.toJson());
  for (var i = 0; i < before.abilityData.length; i++) {
    final old = before.abilityData[i];
    final next = after.abilityData[i];
    _expectPoint(
      next.position + _abilityAnchor(next, _newScale),
      old.position + _abilityAnchor(old, _oldScale),
    );
    expect(next.toJson()..remove('position'), old.toJson()..remove('position'));
  }
  for (var i = 0; i < before.utilityData.length; i++) {
    final old = before.utilityData[i];
    final next = after.utilityData[i];
    _expectPoint(
      next.position + _utilityAnchor(next, _newScale),
      old.position + _utilityAnchor(old, _oldScale),
    );
    expect(next.toJson()..remove('position'), old.toJson()..remove('position'));
  }
  final oldGroup = before.lineUpGroups.single;
  final nextGroup = after.lineUpGroups.single;
  expect(nextGroup.id, oldGroup.id);
  expect(nextGroup.agent.toJson(), oldGroup.agent.toJson());
  final oldItem = oldGroup.items.single;
  final nextItem = nextGroup.items.single;
  _expectPoint(
    nextItem.ability.position + _abilityAnchor(nextItem.ability, _newScale),
    oldItem.ability.position + _abilityAnchor(oldItem.ability, _oldScale),
  );
  expect(
    jsonDecode(jsonEncode(nextItem.toJson()..remove('ability'))),
    jsonDecode(jsonEncode(oldItem.toJson()..remove('ability'))),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('preserves every ability and utility anchor on both sides', () {
    final source = _strategy();
    final before = jsonEncode(
      source.pages.map((p) => p.toJson(source.id)).toList(),
    );
    final result = StrategyProvider.migrateToCurrentVersion(source);
    expect(Maps.mapScale[MapValue.sunset], _newScale);
    expect(result.versionNumber, Settings.versionNumber);
    expect(result.folderID, source.folderID);
    expect(result.createdAt, source.createdAt);
    for (var i = 0; i < source.pages.length; i++) {
      _expectAnchors(source.pages[i], result.pages[i]);
    }
    expect(
      jsonEncode(source.pages.map((p) => p.toJson(source.id)).toList()),
      before,
    );
    expect(
      identical(StrategyProvider.migrateToCurrentVersion(result), result),
      isTrue,
    );
  });

  test('other maps keep their pages unchanged', () {
    final source = _strategy(map: MapValue.split);
    final result = StrategyProvider.migrateToCurrentVersion(source);
    expect(identical(result.pages, source.pages), isTrue);
  });

  test('v96 defense preserves the reflected historical Crosscut center', () {
    final source = _strategy(version: 96, pages: [_page(false)]);
    final before = source.pages.single.abilityData
        .firstWhere((a) => a.data.name == 'Crosscut');
    final result = StrategyProvider.migrateToCurrentVersion(source);
    final after =
        result.pages.single.abilityData.firstWhere((a) => a.id == before.id);
    final oldCenter = before.position +
        const Offset(1, 1) * (30 * 5.78 * _oldScale * _virtualToWorld);
    _expectPoint(after.position + _abilityAnchor(after, _newScale),
        Offset(1000 * 16 / 9 - oldCenter.dx, 1000 - oldCenter.dy));
  });

  test('version 39 and 45 retain their historical Sunset scale', () {
    final crosscut = PlacedAbility(
      id: 'crosscut',
      data: AgentData.agents[AgentType.veto]!.abilities.firstWhere(
        (a) => a.name == 'Crosscut',
      ),
      position: Offset.zero,
    );
    final migrated = AbilityScaleMigration.migratePlacedAbilityPosition(
      ability: crosscut,
      map: MapValue.sunset,
    );
    const shift = 30 * (5.5 * 1.048 - 5.78 * _oldScale);
    _expectPoint(migrated.position, Offset(shift, shift));
    final source = _page(true);
    final oldCircle = source.utilityData.singleWhere(
      (u) => u.type == UtilityType.customCircle,
    );
    final result = CustomCircleWrapperMigration.migratePages(
      pages: [source],
      map: MapValue.sunset,
    ).single;
    final circle = result.utilityData.singleWhere(
      (u) => u.type == UtilityType.customCircle,
    );
    const inset = (40 - 14) * 5.78 * _oldScale;
    _expectPoint(circle.position, oldCircle.position - Offset(inset, inset));
  });

  for (final version in [16, 38, 39, 44, 45, 96]) {
    test(
      'v$version import completes every required migration in order',
      () async {
        final source = _strategy(version: version);
        // Explicit historical stages provide the pre-98 placement reference.
        var historical = StrategyProvider.migrateToWorld16x9(source);
        if (version < 39)
          historical = StrategyProvider.migrateAbilityScale(
            historical,
            force: true,
          );
        if (version < 40)
          historical = StrategyProvider.migrateSquareAoeCenter(
            historical,
            force: true,
          );
        if (version < 45)
          historical = StrategyProvider.migrateCustomCircleWrapper(
            historical,
            force: true,
          );
        if (version < 61)
          historical = StrategyProvider.migrateLineUpGroups(
            historical,
            force: true,
          );
        if (version < 95)
          historical = StrategyProvider.migrateAbilityVisionCones(
            historical,
            force: true,
          );
        if (version < 95)
          historical = StrategyProvider.migratePageNameProvenance(
            historical,
            force: true,
          );
        historical = StrategyProvider.migrateCanonicalCoordinates(
          historical,
          force: true,
        );
        final result = await StrategyProvider.migrateLegacyData(source);
        for (var i = 0; i < historical.pages.length; i++) {
          _expectAnchors(historical.pages[i], result.pages[i]);
        }
      },
    );
  }

  test(
    'pre-page strategies receive the correction after legacy conversion',
    () async {
      final page = _page(false);
      final old = _strategy(version: 15, pages: []).copyWith(
        abilityData: page.abilityData,
        utilityData: page.utilityData,
        agentData: page.agentData.cast<PlacedAgent>(),
        isAttack: false,
      );
      final result = await StrategyProvider.migrateLegacyData(old);
      final paged = await StrategyProvider.migrateLegacyData(
        _strategy(version: 15, pages: [page.copyWith(lineUpGroups: [])]),
      );
      expect(
        result.pages.single.abilityData.map((a) => a.toJson()).toList(),
        paged.pages.single.abilityData.map((a) => a.toJson()).toList(),
      );
      expect(
        result.pages.single.utilityData.map((u) => u.toJson()).toList(),
        paged.pages.single.utilityData.map((u) => u.toJson()).toList(),
      );
      expect(result.versionNumber, Settings.versionNumber);
    },
  );

  test(
    'zip JSON export/import preserves migrated placements without a second shift',
    () async {
      final migrated = await StrategyProvider.migrateLegacyData(_strategy());
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
      final restoredArchive = ZipDecoder().decodeBytes(
        ZipEncoder().encode(archive),
      );
      final decoded = jsonDecode(
        utf8.decode(restoredArchive.files.single.content as List<int>),
      ) as Map<String, dynamic>;
      final pages = await StrategyPage.listFromJson(
        json: jsonEncode(decoded['pages']),
        strategyID: migrated.id,
        isZip: true,
      );
      final restored = await StrategyProvider.migrateLegacyData(
        migrated.copyWith(
          versionNumber: int.parse(decoded['versionNumber'] as String),
          pages: pages,
        ),
      );
      expect(
        restored.pages.map((p) => p.toJson(restored.id)).toList(),
        exportedPages,
      );
    },
  );
}
