import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/migrations/paranoia_range_migration.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

const _virtualToWorld = 1000 / 831;
const _map = MapValue.haven;

final _omen = AgentData.agents[AgentType.omen]!;
final _paranoia = _omen.abilities[1];
final _darkCover = _omen.abilities[2];

Offset _anchor(Ability data) =>
    data.getAnchorPoint(
      mapScale: Maps.mapScale[_map]!,
      abilitySize: Settings.abilitySize,
    ) *
    _virtualToWorld;

PlacedAbility _placed(String id, AbilityInfo info, {bool deleted = false}) =>
    PlacedAbility(
      id: id,
      data: info,
      position: const Offset(610, 340),
      rotation: 0.7,
      isAlly: false,
    )..isDeleted = deleted;

StrategyPage _page(bool attack) => StrategyPage(
      id: attack ? 'attack' : 'defense',
      name: 'Garage retake',
      sortIndex: attack ? 0 : 1,
      isAutoNamed: false,
      isAttack: attack,
      settings: StrategySettings(),
      drawingData: const [],
      agentData: [
        PlacedAgent(
          id: 'omen',
          type: AgentType.omen,
          position: const Offset(340, 210),
        ),
      ],
      abilityData: [
        _placed('paranoia', _paranoia),
        _placed('deleted-paranoia', _paranoia, deleted: true),
        _placed('dark-cover', _darkCover),
      ],
      utilityData: const [],
      textData: const [],
      imageData: const [],
      lineUpGroups: [
        LineUpGroup(
          id: 'group',
          agent: PlacedAgent(
            id: 'lineup-omen',
            type: AgentType.omen,
            position: const Offset(340, 210),
          ),
          items: [
            LineUpItem(
              id: 'item',
              ability: _placed('lineup-paranoia', _paranoia),
              notes: 'Through the garage wall',
            ),
          ],
        ),
      ],
    );

StrategyData _strategy({int version = 103}) => StrategyData(
      id: 'haven',
      name: 'Paranoia range',
      mapData: _map,
      versionNumber: version,
      lastEdited: DateTime.utc(2026, 9, 1),
      folderID: 'folder',
      pages: [_page(true), _page(false)],
    );

void _expectPoint(Offset actual, Offset expected) {
  expect(actual.dx, closeTo(expected.dx, 1e-7));
  expect(actual.dy, closeTo(expected.dy, 1e-7));
}

void _expectOmenEndKept(PlacedAbility before, PlacedAbility after) {
  _expectPoint(
    after.position + _anchor(after.data.abilityData!),
    before.position + _anchor(abilityDataBeforeVersion104(before.data)!),
  );
  expect(
      after.toJson()..remove('position'), before.toJson()..remove('position'));
  expect(after.isDeleted, before.isDeleted);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Paranoia matches the in-game indicator, 28 m by 9 m', () {
    final data = _paranoia.abilityData as SquareAbility;
    expect(data.height, 28 * AgentData.inGameMeters);
    expect(data.width, 9 * AgentData.inGameMeters);
    final old = abilityDataBeforeVersion104(_paranoia) as SquareAbility;
    expect(old.height, 25 * AgentData.inGameMeters);
    expect(old.width, 4.3 * AgentData.inGameMetersDiameter);
  });

  test('v103 Paranoias keep their Omen end on both sides and in lineups', () {
    final source = _strategy();
    final result = StrategyProvider.migrateToCurrentVersion(source);
    expect(result.versionNumber, Settings.versionNumber);
    for (var i = 0; i < source.pages.length; i++) {
      final before = source.pages[i];
      final after = result.pages[i];
      _expectOmenEndKept(before.abilityData[0], after.abilityData[0]);
      _expectOmenEndKept(before.abilityData[1], after.abilityData[1]);
      expect(after.abilityData[2].toJson(), before.abilityData[2].toJson());
      _expectOmenEndKept(
        before.lineUpGroups.single.items.single.ability,
        after.lineUpGroups.single.items.single.ability,
      );
      expect(after.agentData.single.toJson(), before.agentData.single.toJson());
    }
    expect(
      identical(StrategyProvider.migrateToCurrentVersion(result), result),
      isTrue,
    );
  });

  test('strategies without Paranoia keep their pages and edit time', () {
    final page = _page(true);
    final source = _strategy().copyWith(pages: [
      page.copyWith(
        abilityData: [page.abilityData[2]],
        lineUpGraph: page.lineUpGraph.mapNodes(
          ability: (ability) => _placed(ability.id, _darkCover),
        ),
      ),
    ]);
    final result = StrategyProvider.migrateToCurrentVersion(source);
    expect(identical(result.pages, source.pages), isTrue);
    expect(result.lastEdited, source.lastEdited);
    expect(result.versionNumber, Settings.versionNumber);
  });

  test('the far end moves out by 3 m', () {
    final result = StrategyProvider.migrateToCurrentVersion(_strategy());
    final before = _strategy().pages.first.abilityData.first;
    final after = result.pages.first.abilityData.first;
    // Unrotated local frame: the Omen end is the bottom centre, the far end
    // is the top edge.
    final beforeTop = before.position.dy;
    final afterTop = after.position.dy;
    expect(
      beforeTop - afterTop,
      closeTo(
          3 * AgentData.inGameMeters * Maps.mapScale[_map]! * _virtualToWorld,
          1e-7),
    );
  });

  test('zip export/import does not shift Paranoia a second time', () async {
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
  });
}
